#!/usr/bin/env python3
"""Phase F — Compose the viewer scene package (v2, terrain + water only).

Downscales the expanded JPG texture to a browser-friendly size, copies
heightmap, and bundles scene.json. Buildings / roads will come back as a
follow-up pass (SAM2 or similar).
"""
from __future__ import annotations
import datetime
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


def prep_texture() -> None:
    src = C.WORKING_IMAGE
    img = Image.open(src).convert("RGB")
    long_edge = max(img.size)
    if long_edge > C.VIEWER_TEXTURE_LONG_EDGE_PX:
        scale = C.VIEWER_TEXTURE_LONG_EDGE_PX / long_edge
        new_size = (int(img.size[0] * scale), int(img.size[1] * scale))
        img = img.resize(new_size, Image.Resampling.LANCZOS)
    dst = C.VIEWER_PUBLIC / "texture.jpg"
    if dst.exists():
        dst.unlink()
    img.save(dst, "JPEG", quality=86, optimize=True)
    print(f"    texture.jpg  {img.size[0]}×{img.size[1]}  {dst.stat().st_size/1024:.0f} KB")


def copy_heightmap() -> None:
    dst = C.VIEWER_PUBLIC / "heightmap.png"
    if dst.exists():
        dst.unlink()
    src = C.WORK_DIR / "heightmap_small.png"
    dst.write_bytes(src.read_bytes())
    print(f"    heightmap.png  {dst.stat().st_size/1024:.0f} KB")


def main() -> None:
    prep_texture()
    copy_heightmap()

    heightmap_meta = json.loads((C.WORK_DIR / "heightmap_meta.json").read_text())
    water = json.loads((C.WORK_DIR / "water.geojson").read_text())
    # Prefer buildings_tagged.geojson if the landmark-tagging phase ran.
    tagged_path = C.WORK_DIR / "buildings_tagged.geojson"
    buildings_path = C.WORK_DIR / "buildings.geojson"
    if tagged_path.exists():
        buildings = json.loads(tagged_path.read_text())
    elif buildings_path.exists():
        buildings = json.loads(buildings_path.read_text())
    else:
        buildings = {"type": "FeatureCollection", "features": []}
    roads_path = C.WORK_DIR / "roads.geojson"
    roads = (json.loads(roads_path.read_text())
             if roads_path.exists()
             else {"type": "FeatureCollection", "features": []})

    scene = {
        "version": 2,
        "generated_at_iso": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_image": str(C.WORKING_IMAGE.name),
        "world": {
            "image_w_px": C.IMG_W,
            "image_h_px": C.IMG_H,
            "meters_per_pixel": C.METERS_PER_PIXEL,
            "peak_alt_m": C.PEAK_ALT_M,
            "river_alt_m": C.RIVER_ALT_M,
            "world_width_m": C.WORLD_WIDTH_M,
        },
        "assets": {
            "texture_url": "texture.jpg",
            "heightmap_url": "heightmap.png",
            "heightmap_w": C.DEPTH_OUT_W,
            "heightmap_h": C.DEPTH_OUT_H,
        },
        "heightmap_meta": heightmap_meta,
        "water": water,
        "buildings": buildings,
        "roads": roads,
        # Placeholder sun (no shadow-based estimator in v2; buildings gone).
        "sun": {
            "azimuth_deg": 135.0,
            "elevation_deg": 50.0,
            "note": "placeholder; restore shadow-based estimator when buildings return",
        },
    }
    out = C.VIEWER_PUBLIC / "scene.json"
    out.write_text(json.dumps(scene))
    print(f"[F] scene.json written  {out.stat().st_size/1024:.1f} KB")


if __name__ == "__main__":
    main()
