#!/usr/bin/env python3
"""Phase D — Road vectorization.

Strategy (in priority order):

1. **Manual red-line annotation** — if a file exists at
   `<working_map_path>.roads.png` (or `.roads.jpg`), extract red-ish pixels,
   skeletonize, and vectorize. This is the canon-accurate path: Gary traces
   roads over the map in Photoshop once and we pick them up deterministically.

2. **CV fallback** — white top-hat for bright narrow ribbons + oriented Gabor
   for same-tone linear structures, both filtered by low slope and non-water.
   Noisy on stylized AI satellite imagery; use only if no red-line file exists.
"""
from __future__ import annotations
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from skimage.morphology import skeletonize

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


# --- Tunables ---------------------------------------------------------------
PROCESS_DOWNSCALE = 4          # 1/N resolution for analysis
TOPHAT_DISC_PX = 9             # disc kernel radius (process res). Roads < 2R wide pop.
TOPHAT_THRESHOLD = 12          # min brightness above opened background (0-255)

# Gabor/orientation filter — detects elongated structures of ANY tone by
# looking for pixels with strong directional response. Many maps show roads
# as texture changes (smoother than surround) with no tone contrast.
USE_ORIENTATION_FILTER = True
GABOR_KSIZE = 17               # kernel size in process res
GABOR_SIGMA = 3.0
GABOR_LAMBDA = 10.0
GABOR_N_ORIENT = 8             # angles from 0 to π
GABOR_RESPONSE_THRESHOLD = 14  # stronger response than this = candidate

MAX_TERRAIN_SLOPE_DEG = 8.0
MIN_LENGTH_M = 150.0
MIN_PCA_RATIO = 4.0
SIMPLIFY_EPS_PX_PROCESS = 1.5
EDGE_MARGIN_PX = 24
WATER_BUFFER_M = 15.0
BUILDING_BUFFER_M = 10.0


def slope_map_degrees(terrain: np.ndarray, mpp: float) -> np.ndarray:
    dy, dx = np.gradient(terrain)
    slope_tan = np.sqrt(dx * dx + dy * dy) / mpp
    return np.degrees(np.arctan(slope_tan))


def load_full_water_mask() -> np.ndarray:
    p = C.WORK_DIR / "water_mask.png"
    if not p.exists():
        return np.zeros((C.IMG_H, C.IMG_W), dtype=bool)
    return np.array(Image.open(p).convert("L")) > 127


def load_full_buildings_mask() -> np.ndarray:
    p = C.WORK_DIR / "buildings.geojson"
    m = np.zeros((C.IMG_H, C.IMG_W), dtype=np.uint8)
    if not p.exists():
        return m > 0
    data = json.loads(p.read_text())
    for feat in data.get("features", []):
        g = feat.get("geometry", {})
        if g.get("type") != "Polygon":
            continue
        for ring in g.get("coordinates", []):
            pts = np.array(ring, dtype=np.int32)
            cv2.fillPoly(m, [pts], 255)
    return m > 127


def ordered_component_polyline(ys: np.ndarray, xs: np.ndarray) -> tuple[np.ndarray, float]:
    pts = np.stack([xs, ys], axis=1).astype(np.float32)
    if len(pts) < 3:
        return pts, 1.0
    center = pts.mean(axis=0)
    centered = pts - center
    cov = np.cov(centered.T)
    if not np.isfinite(cov).all():
        return pts, 1.0
    evals, evecs = np.linalg.eigh(cov)
    evals = np.clip(evals, 1e-3, None)
    ratio = float(np.sqrt(evals[-1] / evals[0]))
    axis = evecs[:, -1]
    proj = centered @ axis
    order = np.argsort(proj)
    return pts[order], ratio


def polyline_length_px(pts: np.ndarray) -> float:
    if len(pts) < 2:
        return 0.0
    d = np.diff(pts, axis=0)
    return float(np.sqrt((d ** 2).sum(axis=1)).sum())


def find_red_line_annotation() -> Path | None:
    base = C.WORKING_IMAGE
    for suffix in (".roads.png", ".roads.jpg", ".roads.jpeg"):
        candidate = base.with_suffix("").parent / (base.stem + suffix)
        if candidate.exists():
            return candidate
        # Also accept replacing the extension directly.
        sibling = base.parent / (base.stem + suffix)
        if sibling.exists():
            return sibling
    return None


def extract_red_pixels(bgr: np.ndarray) -> np.ndarray:
    """Return a binary mask where the pixel is red-dominant.
    Works for PNG with alpha (handled by caller) or plain JPEG."""
    b, g, r = cv2.split(bgr)
    # Core thresholds: bright red channel, dim green + blue, plus R being
    # clearly higher than G/B so nothing pink or purple slips in.
    mask = (r.astype(np.int16) >= 150) & \
           (r.astype(np.int16) - g.astype(np.int16) >= 60) & \
           (r.astype(np.int16) - b.astype(np.int16) >= 60) & \
           (g.astype(np.int16) <= 120) & \
           (b.astype(np.int16) <= 120)
    return mask.astype(np.uint8) * 255


def roads_from_red_lines(path: Path) -> tuple[list[dict], np.ndarray]:
    print(f"[D] using red-line annotation at {path}")
    img = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    assert img is not None, f"failed to read {path}"
    # Normalize to BGR.
    if img.ndim == 2:
        bgr = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    elif img.shape[2] == 4:
        bgr = img[..., :3]
        alpha = img[..., 3]
        # Mask out transparent regions so they can't pass the colour threshold.
        bgr = bgr.copy()
        bgr[alpha < 16] = 0
    else:
        bgr = img

    # If the annotation isn't already in the working-map pixel space, resize.
    if bgr.shape[1] != C.IMG_W or bgr.shape[0] != C.IMG_H:
        bgr = cv2.resize(bgr, (C.IMG_W, C.IMG_H), interpolation=cv2.INTER_NEAREST)

    red_mask = extract_red_pixels(bgr)
    print(f"[D] red pixels: {int((red_mask > 0).sum())}")

    # Morphological close to bridge any gaps in the trace, then skeletonize.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    closed = cv2.morphologyEx(red_mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    skel = skeletonize(closed > 0)

    n_comp, labels, stats, _ = cv2.connectedComponentsWithStats(
        skel.astype(np.uint8) * 255)
    print(f"[D] red-line components: {n_comp - 1}")

    features = []
    total_m = 0.0
    comp_idx = 0
    # At full resolution, simplify a bit less aggressively than the CV path.
    simp_eps_px = 3.0
    for cid in range(1, n_comp):
        area = stats[cid, cv2.CC_STAT_AREA]
        if area < 8:
            continue
        ys, xs = np.where(labels == cid)
        if len(ys) < 4:
            continue
        ordered, _elong = ordered_component_polyline(ys, xs)
        arr = ordered.reshape(-1, 1, 2).astype(np.float32)
        approx = cv2.approxPolyDP(arr, simp_eps_px, False)
        pts = approx.reshape(-1, 2)
        if len(pts) < 2:
            continue
        length_m = polyline_length_px(pts) * C.METERS_PER_PIXEL
        if length_m < 20.0:
            continue
        coords = [[float(x), float(y)] for x, y in pts]
        features.append({
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": coords},
            "properties": {
                "class": "road",
                "length_m": round(length_m, 1),
                "source": "red-line",
                "component_index": comp_idx,
            },
        })
        total_m += length_m
        comp_idx += 1

    print(f"[D] emitted {len(features)} roads, total length ~{total_m:.0f} m  (red-line source)")
    # Debug overlay uses the working map, not the annotation.
    working_bgr = cv2.imread(str(C.WORKING_IMAGE), cv2.IMREAD_COLOR)
    overlay = working_bgr.copy()
    for feat in features:
        coords = feat["geometry"]["coordinates"]
        pts_arr = np.array([[int(x), int(y)] for x, y in coords], dtype=np.int32)
        cv2.polylines(overlay, [pts_arr], isClosed=False,
                      color=(0, 180, 255), thickness=6)
    return features, overlay


def main() -> None:
    # Manual red-line annotation takes priority over CV heuristics.
    red_path = find_red_line_annotation()
    if red_path is not None:
        features, overlay = roads_from_red_lines(red_path)
        (C.WORK_DIR / "roads.geojson").write_text(
            json.dumps({"type": "FeatureCollection", "features": features}))
        cv2.imwrite(str(C.WORK_DIR / "roads_debug.png"), overlay)
        print("[D] done (red-line path)")
        return

    print(f"[D] no red-line annotation found — falling back to CV heuristic")
    print(f"[D]   expected at: {C.WORKING_IMAGE.with_suffix('').parent / (C.WORKING_IMAGE.stem + '.roads.png')}")
    print(f"[D] reading {C.WORKING_IMAGE}")
    bgr_full = cv2.imread(str(C.WORKING_IMAGE), cv2.IMREAD_COLOR)
    assert bgr_full is not None
    H, W = bgr_full.shape[:2]
    ph, pw = H // PROCESS_DOWNSCALE, W // PROCESS_DOWNSCALE
    process_mpp = C.METERS_PER_PIXEL * PROCESS_DOWNSCALE
    print(f"[D] full: {W}×{H}  process: {pw}×{ph}  mpp={process_mpp:.2f}")

    bgr = cv2.resize(bgr_full, (pw, ph), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

    # (A) White top-hat — bright narrow structures.
    k = TOPHAT_DISC_PX | 1
    disc = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    tophat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, disc)
    road_bright = (tophat >= TOPHAT_THRESHOLD).astype(np.uint8)

    # (B) Oriented response — catches elongated same-tone ribbons via Gabor.
    gray_f = gray.astype(np.float32) / 255.0
    max_response = np.zeros_like(gray_f)
    if USE_ORIENTATION_FILTER:
        for oi in range(GABOR_N_ORIENT):
            theta = oi * np.pi / GABOR_N_ORIENT
            kernel = cv2.getGaborKernel(
                (GABOR_KSIZE, GABOR_KSIZE),
                GABOR_SIGMA, theta, GABOR_LAMBDA, 0.5, 0,
                ktype=cv2.CV_32F,
            )
            kernel -= kernel.mean()
            resp = cv2.filter2D(gray_f, cv2.CV_32F, kernel)
            max_response = np.maximum(max_response, np.abs(resp))
    road_oriented = (max_response * 255 >= GABOR_RESPONSE_THRESHOLD).astype(np.uint8)

    road_cand = np.maximum(road_bright, road_oriented) * 255

    # Slope filter.
    height_full = np.load(C.WORK_DIR / "heightmap.npy").astype(np.float32)
    height = cv2.resize(height_full, (pw, ph), interpolation=cv2.INTER_AREA)
    k_lp = (max(3, int(60.0 / process_mpp)) // 2) * 2 + 1
    terrain = cv2.GaussianBlur(height, (k_lp, k_lp), 0)
    slope_deg = slope_map_degrees(terrain, process_mpp)
    low_slope = (slope_deg < MAX_TERRAIN_SLOPE_DEG).astype(np.uint8) * 255

    # Water + building exclusions with small buffers.
    water_full = load_full_water_mask()
    water = cv2.resize(water_full.astype(np.uint8), (pw, ph),
                       interpolation=cv2.INTER_NEAREST) > 0
    buildings_full = load_full_buildings_mask()
    buildings = cv2.resize(buildings_full.astype(np.uint8), (pw, ph),
                           interpolation=cv2.INTER_NEAREST) > 0
    water_buf_px = max(1, int(WATER_BUFFER_M / process_mpp))
    water_dil = cv2.dilate(water.astype(np.uint8),
                           cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                                     (water_buf_px * 2 + 1,) * 2)) > 0
    bld_buf_px = max(1, int(BUILDING_BUFFER_M / process_mpp))
    bld_dil = cv2.dilate(buildings.astype(np.uint8),
                         cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                                   (bld_buf_px * 2 + 1,) * 2)) > 0

    road_cand[low_slope == 0] = 0
    road_cand[water_dil] = 0
    road_cand[bld_dil] = 0
    road_cand[:EDGE_MARGIN_PX, :] = 0
    road_cand[-EDGE_MARGIN_PX:, :] = 0
    road_cand[:, :EDGE_MARGIN_PX] = 0
    road_cand[:, -EDGE_MARGIN_PX:] = 0

    # Slight close to bridge gaps, then skeletonize.
    close_k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    road_cand = cv2.morphologyEx(road_cand, cv2.MORPH_CLOSE, close_k, iterations=1)
    print(f"[D] candidate pixels: {int((road_cand > 0).sum())}")
    skel = skeletonize(road_cand > 0)

    n_comp, labels, stats, _ = cv2.connectedComponentsWithStats(
        skel.astype(np.uint8) * 255)
    print(f"[D] raw components: {n_comp - 1}")

    features = []
    total_m = 0.0
    comp_idx = 0
    for cid in range(1, n_comp):
        area = stats[cid, cv2.CC_STAT_AREA]
        if area < 4:
            continue
        ys, xs = np.where(labels == cid)
        if len(ys) < 4:
            continue
        ordered, elong = ordered_component_polyline(ys, xs)
        if elong < MIN_PCA_RATIO:
            continue
        ordered_full = ordered * PROCESS_DOWNSCALE
        arr = ordered_full.reshape(-1, 1, 2).astype(np.float32)
        approx = cv2.approxPolyDP(arr, SIMPLIFY_EPS_PX_PROCESS * PROCESS_DOWNSCALE, False)
        pts = approx.reshape(-1, 2)
        if len(pts) < 2:
            continue
        length_m = polyline_length_px(pts) * C.METERS_PER_PIXEL
        if length_m < MIN_LENGTH_M:
            continue
        coords = [[float(x), float(y)] for x, y in pts]
        features.append({
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": coords},
            "properties": {
                "class": "road",
                "length_m": round(length_m, 1),
                "elongation": round(elong, 2),
                "component_index": comp_idx,
            },
        })
        total_m += length_m
        comp_idx += 1

    print(f"[D] emitted {len(features)} roads, total length ~{total_m:.0f} m")
    (C.WORK_DIR / "roads.geojson").write_text(
        json.dumps({"type": "FeatureCollection", "features": features}))

    # Debug overlay.
    overlay = bgr_full.copy()
    for feat in features:
        coords = feat["geometry"]["coordinates"]
        pts_arr = np.array([[int(x), int(y)] for x, y in coords], dtype=np.int32)
        cv2.polylines(overlay, [pts_arr], isClosed=False,
                      color=(0, 220, 255), thickness=4)
    cv2.imwrite(str(C.WORK_DIR / "roads_debug.png"), overlay)
    print("[D] done")


if __name__ == "__main__":
    main()
