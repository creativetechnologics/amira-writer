#!/usr/bin/env python3
"""Phase G — Tag detected buildings with named landmarks from Amira Writer's
canonical Places data (places-master-map-layers.json).

Inputs:
  work/buildings.geojson                   — building FeatureCollection (pixel coords)
  ASSETS_ROOT/places-master-map-layers.json — canonical landmark/building catalogue
  ASSETS_ROOT/backgrounds/chosen-references/map/
    02-master_valley_topdown_map_expanded_2026-04-14.mapmeta.json
      — logicalContentRectNormalized rect for the old-4K→expanded transform

Outputs:
  work/buildings_tagged.geojson  — same features, enriched properties
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
MATCH_RADIUS_M: float = 250.0  # max distance to claim a canonical name


# ---------------------------------------------------------------------------
# Coordinate transform helpers
# ---------------------------------------------------------------------------

def load_mapmeta_rect() -> dict:
    """Return logicalContentRectNormalized from the 02 expanded mapmeta.

    Falls back to the identity rect (full raster = old-4K space) with a
    warning if the file is missing.
    """
    mapmeta_path = (
        C.ASSETS_ROOT
        / "backgrounds/chosen-references/map"
        / "02-master_valley_topdown_map_expanded_2026-04-14.mapmeta.json"
    )
    if not mapmeta_path.exists():
        print(
            f"[G] WARNING: mapmeta not found at {mapmeta_path}. "
            "Falling back to identity transform (normalized coords cover full raster)."
        )
        return {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0}

    meta = json.loads(mapmeta_path.read_text())
    rect = meta.get("logicalContentRectNormalized")
    if not rect or not all(k in rect for k in ("x", "y", "width", "height")):
        print(
            "[G] WARNING: mapmeta missing logicalContentRectNormalized. "
            "Falling back to identity transform."
        )
        return {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0}

    return rect


def normalized_to_pixel(nx: float, ny: float, rect: dict) -> tuple[float, float]:
    """Convert a normalized (0..1) coord from the OLD 4K map's space into
    pixel coordinates in the expanded 10200×5380 working raster.

    Formula:
        px = (rect.x + nx * rect.width)  * IMG_W
        py = (rect.y + ny * rect.height) * IMG_H
    """
    px = (rect["x"] + nx * rect["width"]) * C.IMG_W
    py = (rect["y"] + ny * rect["height"]) * C.IMG_H
    return px, py


# ---------------------------------------------------------------------------
# Canonical entry loading
# ---------------------------------------------------------------------------

def load_canonical_entries(rect: dict) -> list[dict]:
    """Return all landmark + building entries from places-master-map-layers.json
    as dicts with unified pixel coords `px`, `py`.

    Deduplication rule: when multiple records share the same placeID/id core,
    keep them all — matching is by distance, not ID uniqueness.  The caller
    will always find the NEAREST entry, so duplicates only help precision.
    """
    layers_path = C.ASSETS_ROOT / "places-master-map-layers.json"
    data = json.loads(layers_path.read_text())
    layers = data.get("layers", {})

    entries: list[dict] = []

    # ---- landmarks (have x, y) ------------------------------------------------
    for lm in layers.get("landmarks", []):
        nx = lm.get("x")
        ny = lm.get("y")
        if nx is None or ny is None:
            continue
        px, py = normalized_to_pixel(nx, ny, rect)
        entries.append({
            "id": lm["id"],
            "title": lm.get("title", ""),
            "kind": lm.get("kind", ""),
            "px": px,
            "py": py,
        })

    # ---- buildings (have anchorX, anchorY) ------------------------------------
    for bld in layers.get("buildings", []):
        nx = bld.get("anchorX")
        ny = bld.get("anchorY")
        if nx is None or ny is None:
            continue
        px, py = normalized_to_pixel(nx, ny, rect)
        entries.append({
            "id": bld["id"],
            "title": bld.get("title", ""),
            "kind": bld.get("kind", ""),
            "px": px,
            "py": py,
        })

    return entries


# ---------------------------------------------------------------------------
# Distance helpers
# ---------------------------------------------------------------------------

def pixel_dist_m(ax: float, ay: float, bx: float, by: float) -> float:
    """Euclidean pixel distance converted to metres."""
    dx = ax - bx
    dy = ay - by
    return math.sqrt(dx * dx + dy * dy) * C.METERS_PER_PIXEL


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    # -- Load buildings -------------------------------------------------------
    buildings_path = C.WORK_DIR / "buildings.geojson"
    fc = json.loads(buildings_path.read_text())
    features = fc.get("features", [])
    print(f"[G] loaded {len(features)} buildings from {buildings_path.name}")

    # -- Coordinate transform -------------------------------------------------
    rect = load_mapmeta_rect()
    print(
        f"[G] mapmeta rect: x={rect['x']:.6f} y={rect['y']:.6f} "
        f"w={rect['width']:.6f} h={rect['height']:.6f}"
    )

    # -- Load canonical entries -----------------------------------------------
    canonical = load_canonical_entries(rect)
    print(f"[G] loaded {len(canonical)} canonical landmark/building entries")

    if not canonical:
        print("[G] WARNING: no canonical entries — all buildings will be untagged.")

    # -- Tag each building ----------------------------------------------------
    match_radius_px = MATCH_RADIUS_M / C.METERS_PER_PIXEL
    matched_count = 0

    for feat in features:
        props = feat.setdefault("properties", {})
        cp = props.get("centroid_px")
        if cp is None or len(cp) < 2:
            continue
        bx, by = float(cp[0]), float(cp[1])

        if not canonical:
            continue

        # Compute distances to ALL canonical entries.
        distances: list[tuple[float, dict]] = []
        for entry in canonical:
            d = pixel_dist_m(bx, by, entry["px"], entry["py"])
            distances.append((d, entry))

        distances.sort(key=lambda t: t[0])
        nearest_d, nearest_entry = distances[0]

        # Always record the nearest landmark regardless of match radius.
        props["nearest_landmark"] = {
            "id": nearest_entry["id"],
            "title": nearest_entry["title"],
            "distance_m": round(nearest_d, 1),
        }

        # Within-radius match → name the building.
        if nearest_d <= MATCH_RADIUS_M:
            props["label"] = nearest_entry["title"]
            props["canonical_id"] = nearest_entry["id"]
            props["canonical_kind"] = nearest_entry["kind"]
            matched_count += 1

    # -- Summary stats --------------------------------------------------------
    all_dists = []
    for feat in features:
        nl = feat.get("properties", {}).get("nearest_landmark")
        if nl:
            all_dists.append(nl["distance_m"])

    if all_dists:
        all_dists_sorted = sorted(all_dists)
        n = len(all_dists_sorted)
        median_d = all_dists_sorted[n // 2]
        max_d = all_dists_sorted[-1]
        print(
            f"[G] matched {matched_count}/{len(features)} buildings to named landmarks. "
            f"Nearest-landmark distances: median={median_d:.1f} m, max={max_d:.1f} m"
        )
    else:
        print(f"[G] matched {matched_count}/{len(features)} buildings to named landmarks.")

    # -- Write output ---------------------------------------------------------
    out_path = C.WORK_DIR / "buildings_tagged.geojson"
    out_path.write_text(json.dumps(fc, ensure_ascii=False))
    print(f"[G] wrote {out_path}")


if __name__ == "__main__":
    main()
