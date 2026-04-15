#!/usr/bin/env python3
"""Phase C — Building detection via SAM 2 Automatic Mask Generator on the
village ROI.

Previous heightmap-bump approach missed most village houses. SAM2 on the full
landscape produces too-coarse masks; SAM2 on a cropped village ROI produces
per-house masks at a useful granularity.

Village ROI is determined from the canonical places data in
`places-master-map-layers.json` — we read the village-kind landmarks,
transform them into the current map's pixel space via the expanded-map
mapmeta, and take their bounding box plus a buffer. This is robust across
map iterations as long as the canon anchors track the new map.

Outputs:
  work/buildings.geojson     — FeatureCollection (pixel coords, full-res)
  work/buildings_debug.png   — RGB overlay showing detected building polygons
"""
from __future__ import annotations
import json
import os
import sys
from pathlib import Path

os.environ.setdefault("HYDRA_FULL_ERROR", "0")

import cv2
import numpy as np
import torch
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402

from sam2.build_sam import build_sam2  # noqa: E402
from sam2.automatic_mask_generator import SAM2AutomaticMaskGenerator  # noqa: E402


# --- Tunables --------------------------------------------------------------
SAM2_CFG_NAME = "configs/sam2.1/sam2.1_hiera_t.yaml"
SAM2_WEIGHTS = Path.home() / ".cache/sam2/sam2.1_hiera_tiny.pt"

# Village ROI derived from canonical landmarks.
VILLAGE_LANDMARK_KINDS = {
    "amira_home", "gathering_space", "clinic", "marketplace",
    "bridge", "riverside",
}
VILLAGE_BUFFER_M = 260.0  # pad the landmark bbox by this much

# SAM2 AMG tuning — aggressive on the cropped ROI.
AMG_POINTS_PER_SIDE = 64
AMG_PRED_IOU_THRESH = 0.68
AMG_STABILITY_THRESH = 0.82
AMG_MIN_REGION_AREA = 25
AMG_CROP_N_LAYERS = 1           # one extra crop layer doubles masks at cost
AMG_BOX_NMS_THRESH = 0.5        # allow more overlapping masks

# Building geometry filters (in full-resolution pixel space).
MIN_AREA_M2 = 5.0
MAX_AREA_M2 = 500.0
MIN_COMPACTNESS = 0.15
MAX_ASPECT_RATIO = 7.0
WATER_OVERLAP_MAX = 0.10

SIMPLIFY_EPS_FRAC = 0.0015   # tight simplification so rooftops keep their outline
SIMPLIFY_EPS_MIN = 0.5
MIN_HEIGHT_M = 3.0
MAX_HEIGHT_M = 15.0
ANNULUS_PAD_PX = 20


def pick_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def find_village_roi() -> tuple[int, int, int, int]:
    """Return (x0, y0, x1, y1) in full-res pixels enclosing the village
    landmarks plus VILLAGE_BUFFER_M. Falls back to a centre-biased box if
    canon data is missing."""
    layers_path = C.ASSETS_ROOT / "places-master-map-layers.json"
    meta_path = (C.ASSETS_ROOT
                 / "backgrounds/chosen-references/map/02-master_valley_topdown_map_expanded_2026-04-14.mapmeta.json")

    if not layers_path.exists() or not meta_path.exists():
        print("[C] canon JSON missing → falling back to centre-biased ROI")
        cx, cy = C.IMG_W // 2, int(C.IMG_H * 0.42)
        half = int(1200 / C.METERS_PER_PIXEL / 2)
        return (cx - half, cy - half // 2, cx + half, cy + half // 2)

    layers = json.loads(layers_path.read_text()).get("layers", {})
    meta = json.loads(meta_path.read_text())
    rect = meta.get("logicalContentRectNormalized") or {}
    rx = float(rect.get("x", 0))
    ry = float(rect.get("y", 0))
    rw = float(rect.get("width", 1))
    rh = float(rect.get("height", 1))

    xs: list[float] = []
    ys: list[float] = []
    for entry in layers.get("landmarks", []):
        if entry.get("kind") in VILLAGE_LANDMARK_KINDS and "x" in entry and "y" in entry:
            xs.append((rx + float(entry["x"]) * rw) * C.IMG_W)
            ys.append((ry + float(entry["y"]) * rh) * C.IMG_H)
    for b in layers.get("buildings", []):
        if b.get("kind") in VILLAGE_LANDMARK_KINDS and "anchorX" in b and "anchorY" in b:
            xs.append((rx + float(b["anchorX"]) * rw) * C.IMG_W)
            ys.append((ry + float(b["anchorY"]) * rh) * C.IMG_H)
    if not xs:
        print("[C] no village landmarks found → falling back to centre-biased ROI")
        cx, cy = C.IMG_W // 2, int(C.IMG_H * 0.42)
        half = int(1200 / C.METERS_PER_PIXEL / 2)
        return (cx - half, cy - half // 2, cx + half, cy + half // 2)

    pad_px = int(VILLAGE_BUFFER_M / C.METERS_PER_PIXEL)
    x0 = max(0, int(min(xs)) - pad_px)
    y0 = max(0, int(min(ys)) - pad_px)
    x1 = min(C.IMG_W, int(max(xs)) + pad_px)
    y1 = min(C.IMG_H, int(max(ys)) + pad_px)
    return (x0, y0, x1, y1)


def load_water_mask_full() -> np.ndarray:
    p = C.WORK_DIR / "water_mask.png"
    if not p.exists():
        return np.zeros((C.IMG_H, C.IMG_W), dtype=bool)
    return np.array(Image.open(p).convert("L")) > 127


def contour_to_ring(mask_bool: np.ndarray) -> list[list[float]]:
    binary = (mask_bool.astype(np.uint8) * 255)
    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_TC89_L1)
    if not contours:
        return []
    outer = max(contours, key=cv2.contourArea)
    eps = max(SIMPLIFY_EPS_MIN, SIMPLIFY_EPS_FRAC * cv2.arcLength(outer, True))
    approx = cv2.approxPolyDP(outer, eps, True).squeeze(1)
    if approx.ndim != 2 or len(approx) < 3:
        return []
    return [[float(x), float(y)] for x, y in approx]


def centroid_of(ring: list[list[float]]) -> tuple[float, float]:
    pts = np.array(ring, dtype=np.float32)
    m = cv2.moments(pts)
    if m["m00"] < 1e-3:
        return float(pts[:, 0].mean()), float(pts[:, 1].mean())
    return m["m10"] / m["m00"], m["m01"] / m["m00"]


def sample_bump_height(height_m: np.ndarray, ring: list[list[float]]) -> float:
    H, W = height_m.shape
    poly = np.array(ring, dtype=np.int32).reshape(-1, 2)
    inner = np.zeros((H, W), dtype=np.uint8)
    cv2.fillPoly(inner, [poly], 255)
    outer = cv2.dilate(inner, np.ones((ANNULUS_PAD_PX * 2 + 1,) * 2, np.uint8))
    ring_mask = (outer > 0) & (inner == 0)
    inner_mask = inner > 0
    inner_alt = float(np.median(height_m[inner_mask])) if inner_mask.any() else 0.0
    outer_alt = float(np.median(height_m[ring_mask])) if ring_mask.any() else inner_alt
    return max(0.0, inner_alt - outer_alt)


def main() -> None:
    device = pick_device()
    print(f"[C] device={device}")

    x0, y0, x1, y1 = find_village_roi()
    w_roi = x1 - x0
    h_roi = y1 - y0
    print(f"[C] village ROI: ({x0}, {y0}) → ({x1}, {y1})  {w_roi}×{h_roi} px "
          f"(~{w_roi * C.METERS_PER_PIXEL:.0f}×{h_roi * C.METERS_PER_PIXEL:.0f} m)")

    bgr_full = cv2.imread(str(C.WORKING_IMAGE), cv2.IMREAD_COLOR)
    assert bgr_full is not None
    roi_bgr = bgr_full[y0:y1, x0:x1]
    roi_rgb = cv2.cvtColor(roi_bgr, cv2.COLOR_BGR2RGB)

    print(f"[C] building SAM2 (tiny) on {device}")
    model = build_sam2(
        config_file=SAM2_CFG_NAME,
        ckpt_path=str(SAM2_WEIGHTS),
        device=device,
    )
    amg = SAM2AutomaticMaskGenerator(
        model=model,
        points_per_side=AMG_POINTS_PER_SIDE,
        points_per_batch=64,
        pred_iou_thresh=AMG_PRED_IOU_THRESH,
        stability_score_thresh=AMG_STABILITY_THRESH,
        stability_score_offset=0.7,
        box_nms_thresh=AMG_BOX_NMS_THRESH,
        crop_n_layers=AMG_CROP_N_LAYERS,
        crop_n_points_downscale_factor=2,
        min_mask_region_area=AMG_MIN_REGION_AREA,
    )
    print(f"[C] running AMG on {roi_rgb.shape[1]}×{roi_rgb.shape[0]} ROI…")
    masks = amg.generate(roi_rgb)
    print(f"[C] raw masks: {len(masks)}")

    water_full = load_water_mask_full()
    roi_water = water_full[y0:y1, x0:x1]
    height_full = np.load(C.WORK_DIR / "heightmap.npy").astype(np.float32)

    kept_features = []
    overlay = roi_rgb.copy()
    for m in masks:
        area_roi = int(m["area"])
        area_m2 = area_roi * (C.METERS_PER_PIXEL ** 2)
        if not (MIN_AREA_M2 <= area_m2 <= MAX_AREA_M2):
            continue
        x, y, w, h = m["bbox"]
        if w <= 0 or h <= 0:
            continue
        aspect = max(w, h) / max(1.0, min(w, h))
        if aspect > MAX_ASPECT_RATIO:
            continue
        compactness = area_roi / (w * h + 1e-6)
        if compactness < MIN_COMPACTNESS:
            continue
        seg = m["segmentation"]
        if roi_water.any():
            overlap = float((seg & roi_water).sum()) / max(seg.sum(), 1)
            if overlap > WATER_OVERLAP_MAX:
                continue
        ring_roi = contour_to_ring(seg)
        if not ring_roi:
            continue
        # Shift into full-image coordinates.
        ring_full = [[x0 + p[0], y0 + p[1]] for p in ring_roi]
        area_full_px = cv2.contourArea(np.array(ring_full, dtype=np.float32))
        area_m2_full = float(area_full_px * (C.METERS_PER_PIXEL ** 2))
        cx_full, cy_full = centroid_of(ring_full)
        # Height: blend heightmap bump + size heuristic.
        bump = sample_bump_height(height_full, ring_full)
        size_cue = 3.0 + (area_m2_full ** 0.5) * 0.28
        height_m_val = max(MIN_HEIGHT_M, min(MAX_HEIGHT_M, max(bump, size_cue)))
        base_alt_m = float(height_full[min(C.IMG_H - 1, int(cy_full)),
                                       min(C.IMG_W - 1, int(cx_full))]) - bump
        kept_features.append({
            "type": "Feature",
            "geometry": {"type": "Polygon", "coordinates": [ring_full]},
            "properties": {
                "class": "building",
                "area_px": float(area_full_px),
                "area_m2": round(area_m2_full, 1),
                "height_m": round(height_m_val, 2),
                "base_alt_m": round(base_alt_m, 2),
                "peak_bump_m": round(bump, 2),
                "height_source": "sam2_roi",
                "centroid_px": [cx_full, cy_full],
                "predicted_iou": float(m.get("predicted_iou", 0)),
            },
        })
        ys_, xs_ = np.nonzero(seg)
        overlay[ys_, xs_] = (0.55 * overlay[ys_, xs_] +
                             0.45 * np.array([255, 120, 40])).astype(np.uint8)

    print(f"[C] kept {len(kept_features)} buildings after filter")

    out = {"type": "FeatureCollection", "features": kept_features}
    (C.WORK_DIR / "buildings.geojson").write_text(json.dumps(out))

    # Debug overlay on full image (only ROI painted).
    full_overlay = bgr_full.copy()
    full_overlay_rgb = cv2.cvtColor(full_overlay, cv2.COLOR_BGR2RGB)
    full_overlay_rgb[y0:y1, x0:x1] = (
        0.6 * full_overlay_rgb[y0:y1, x0:x1] + 0.4 * overlay).astype(np.uint8)
    cv2.rectangle(full_overlay_rgb, (x0, y0), (x1, y1), (80, 200, 255), 8)
    cv2.imwrite(str(C.WORK_DIR / "buildings_debug.png"),
                cv2.cvtColor(full_overlay_rgb, cv2.COLOR_RGB2BGR))
    print("[C] wrote buildings.geojson + buildings_debug.png")


if __name__ == "__main__":
    main()
