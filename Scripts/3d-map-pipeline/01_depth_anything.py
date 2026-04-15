#!/usr/bin/env python3
"""Phase A — Terrain DEM from the expanded master map via Depth Anything V2.

Input: 10200 × 5380 JPG (the expanded Amira valley master map).
Output:
  work/heightmap.npy       — raw float32 metres ASL, shape (H, W) — full res
  work/heightmap.png       — 16-bit grayscale (archival)
  work/heightmap_norm.png  — 8-bit quicklook
  work/heightmap_small.png — packed 16-bit RG for the browser viewer
  work/heightmap_meta.json — scaling constants + stats

Strategy: one whole-image DA V2 pass (the DPT processor resizes to 518
internally, preserving aspect). We then upsample, smooth, and anchor to real
metres via percentile clamping (river ≈ pct 2, peak ≈ pct 99). No segmentation
dependency — this script reads nothing but the RGB map.
"""
from __future__ import annotations
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from scipy.ndimage import gaussian_filter
from transformers import AutoImageProcessor, AutoModelForDepthEstimation

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_config as C  # noqa: E402


def pick_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def main() -> None:
    device = pick_device()
    print(f"[A] device={device}  model={C.DEPTH_MODEL_ID}")

    print(f"[A] loading image: {C.WORKING_IMAGE}")
    img = Image.open(C.WORKING_IMAGE).convert("RGB")
    print(f"[A] image size: {img.size}")

    print("[A] loading model…")
    t0 = time.time()
    processor = AutoImageProcessor.from_pretrained(C.DEPTH_MODEL_ID)
    model = AutoModelForDepthEstimation.from_pretrained(C.DEPTH_MODEL_ID)
    model = model.to(device).eval()
    print(f"[A] model loaded in {time.time() - t0:.1f}s")

    print("[A] running inference…")
    t0 = time.time()
    inputs = processor(images=img, return_tensors="pt").to(device)
    with torch.no_grad():
        out = model(**inputs)
    depth = out.predicted_depth  # (1, h, w)
    # Upsample to the full working resolution.
    depth = torch.nn.functional.interpolate(
        depth.unsqueeze(1),
        size=(C.IMG_H, C.IMG_W),
        mode="bicubic",
        align_corners=False,
    ).squeeze().cpu().float().numpy()
    print(f"[A] inference {time.time() - t0:.1f}s  shape={depth.shape}")

    # DA V2 output: larger value = closer to camera. Overhead camera -> closer
    # = higher altitude. Raw depth acts as an altitude proxy.
    raw = depth.astype(np.float32)

    # Anchor via percentiles. No segmentation dependency.
    river_raw = float(np.percentile(raw, 2))
    peak_raw = float(np.percentile(raw, 99))
    print(f"[A] river_raw(pct2)={river_raw:.4f}  peak_raw(pct99)={peak_raw:.4f}")
    if peak_raw <= river_raw:
        peak_raw = river_raw + 1.0
    scale = (C.PEAK_ALT_M - C.RIVER_ALT_M) / (peak_raw - river_raw)
    altitude_m = (raw - river_raw) * scale + C.RIVER_ALT_M
    altitude_m = np.clip(altitude_m, -20.0, C.PEAK_ALT_M + 60.0)

    # Suppress high-frequency peak noise from DA V2.
    altitude_m = gaussian_filter(altitude_m, sigma=8.0)

    # Archival saves.
    np.save(C.WORK_DIR / "heightmap.npy", altitude_m)
    h_norm = np.clip(altitude_m / C.PEAK_ALT_M, 0.0, 1.0)
    h16 = (h_norm * 65535.0).astype(np.uint16)
    Image.fromarray(h16).save(C.WORK_DIR / "heightmap.png")
    Image.fromarray((h_norm * 255).astype(np.uint8), mode="L").save(
        C.WORK_DIR / "heightmap_norm.png"
    )

    # Viewer-ready packed RG 16-bit, downsampled.
    small_h16 = np.array(
        Image.fromarray(h16).resize(
            (C.DEPTH_OUT_W, C.DEPTH_OUT_H), Image.Resampling.LANCZOS
        )
    )
    packed = np.zeros((*small_h16.shape, 4), dtype=np.uint8)
    packed[..., 0] = (small_h16 >> 8) & 0xFF
    packed[..., 1] = small_h16 & 0xFF
    packed[..., 2] = 0
    packed[..., 3] = 255
    Image.fromarray(packed, mode="RGBA").save(C.WORK_DIR / "heightmap_small.png")

    meta = {
        "working_resolution": [C.IMG_W, C.IMG_H],
        "meters_per_pixel": C.METERS_PER_PIXEL,
        "peak_alt_m": C.PEAK_ALT_M,
        "river_alt_m": C.RIVER_ALT_M,
        "world_width_m": C.WORLD_WIDTH_M,
        "anchor": {
            "river_raw_pct2": river_raw,
            "peak_raw_pct99": peak_raw,
            "scale": scale,
        },
        "model": C.DEPTH_MODEL_ID,
        "device": device,
    }
    (C.WORK_DIR / "heightmap_meta.json").write_text(json.dumps(meta, indent=2))
    print("[A] done:")
    for p in ["heightmap.npy", "heightmap.png", "heightmap_norm.png",
              "heightmap_small.png", "heightmap_meta.json"]:
        print(f"    {C.WORK_DIR / p}")


if __name__ == "__main__":
    main()
