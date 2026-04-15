#!/usr/bin/env python3
"""Phase B — Classical water segmentation (HSV + connected-component).

Fully replaces the prior Gemini-mask dependency. Reads only the expanded RGB
map and writes:
  work/water_mask.png     — binary mask at working resolution
  work/water.geojson      — polygon(s) in pixel coordinates
  work/water_debug.png    — overlay for sanity-checking

Tunables at the top. Defaults tuned for the Amira Himalayan-valley aesthetic:
  - blue/cyan hue window
  - moderate saturation floor (rocks can look slightly blueish)
  - area floor to reject shadow puddles
"""
from __future__ import annotations
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


# OpenCV HSV: H in [0, 179], S in [0, 255], V in [0, 255].
HUE_MIN, HUE_MAX = 85, 115      # cyan -> blue
SAT_MIN = 40
VAL_MIN, VAL_MAX = 60, 240
MIN_AREA_PX = 4000               # reject specks (river is far bigger)
SIMPLIFY_EPS_FRAC = 0.002
SIMPLIFY_EPS_MIN = 2.0


def main() -> None:
    print(f"[B] reading {C.WORKING_IMAGE}")
    bgr = cv2.imread(str(C.WORKING_IMAGE), cv2.IMREAD_COLOR)
    assert bgr is not None, "failed to read expanded map"
    H, W = bgr.shape[:2]
    print(f"[B] image shape: {W}×{H}")

    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    lo = np.array([HUE_MIN, SAT_MIN, VAL_MIN], dtype=np.uint8)
    hi = np.array([HUE_MAX, 255, VAL_MAX], dtype=np.uint8)
    mask = cv2.inRange(hsv, lo, hi)

    # Morphology: small-scale noise removal, then a light close to bridge gaps.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)

    # Keep only connected components with substantial area.
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    keep = np.zeros_like(mask)
    for i in range(1, n):
        if stats[i, cv2.CC_STAT_AREA] >= MIN_AREA_PX:
            keep[labels == i] = 255
    mask = keep

    Image.fromarray(mask).save(C.WORK_DIR / "water_mask.png")

    # Debug overlay.
    overlay = bgr.copy()
    blue_tint = np.zeros_like(overlay)
    blue_tint[..., 0] = 255  # BGR -> strong blue
    overlay = np.where(mask[..., None] > 0,
                       (0.5 * overlay + 0.5 * blue_tint).astype(np.uint8),
                       overlay)
    cv2.imwrite(str(C.WORK_DIR / "water_debug.png"), overlay)

    # Vectorize.
    contours, hierarchy = cv2.findContours(mask, cv2.RETR_CCOMP,
                                           cv2.CHAIN_APPROX_TC89_L1)
    features = []
    if contours:
        hier = hierarchy[0] if hierarchy is not None else []
        outer_indices = [i for i, h in enumerate(hier) if h[3] == -1]
        for idx, oi in enumerate(outer_indices):
            outer = contours[oi]
            area = cv2.contourArea(outer)
            if area < MIN_AREA_PX:
                continue
            ring = simplify(outer)
            if len(ring) < 3:
                continue
            holes = []
            for j, h in enumerate(hier):
                if h[3] == oi:
                    hole_area = cv2.contourArea(contours[j])
                    if hole_area < MIN_AREA_PX / 4:
                        continue
                    hole_ring = simplify(contours[j])
                    if len(hole_ring) >= 3:
                        holes.append(hole_ring)
            coords = [ring, *holes]
            features.append({
                "type": "Feature",
                "geometry": {"type": "Polygon", "coordinates": coords},
                "properties": {"class": "water", "index": idx, "area_px": float(area)},
            })
    print(f"[B] water features: {len(features)}")
    out = {"type": "FeatureCollection", "features": features}
    (C.WORK_DIR / "water.geojson").write_text(json.dumps(out))


def simplify(contour: np.ndarray) -> list[list[float]]:
    eps = max(SIMPLIFY_EPS_MIN,
              SIMPLIFY_EPS_FRAC * cv2.arcLength(contour, True))
    approx = cv2.approxPolyDP(contour, eps, True).squeeze(1)
    return [[float(x), float(y)] for x, y in approx]


if __name__ == "__main__":
    main()
