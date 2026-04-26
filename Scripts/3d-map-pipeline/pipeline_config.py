"""Central config for the 3D map pipeline (v2 — expanded map, no Gemini deps).

One place to change paths, metric anchors, and tunables. All scripts import this.
"""
from __future__ import annotations
from pathlib import Path

# --- Input -----------------------------------------------------------------
# The canonical working master map. Everything in this pipeline runs on this
# image directly — no upstream segmentation pack required.
ASSETS_ROOT = Path(
    "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate"
)
# V5 (2026-04-22 Gemini Nano Banana 2 edit): latest iteration from Gary.
# This image is the inner-content map (6336 × 2688) — NOT the prior expanded
# 10200 × 5380 format. Its sidecar mapmeta declares logicalContentRect = 0..1
# so per-landmark coordinates resolve directly to pixel coords without an
# inner-content offset. The variable name is kept as EXPANDED_MAP for
# backwards compatibility with the existing scripts; treat it as "the working
# raster".
EXPANDED_MAP = (
    ASSETS_ROOT
    / "backgrounds/chosen-references/map/05-master_valley_topdown_map_2026-04-22.png"
)
WORKING_IMAGE = EXPANDED_MAP

# --- Paths -----------------------------------------------------------------
PIPELINE_ROOT = Path(__file__).resolve().parent
WORK_DIR = PIPELINE_ROOT / "work"
VIEWER_DIR = PIPELINE_ROOT / "viewer"
VIEWER_PUBLIC = VIEWER_DIR  # web root
WORK_DIR.mkdir(parents=True, exist_ok=True)
VIEWER_DIR.mkdir(parents=True, exist_ok=True)

# --- Working resolution ----------------------------------------------------
# v5 (2026-04-22) is the inner content directly (no expanded margins).
IMG_W, IMG_H = 6336, 2688

# --- Metric anchors --------------------------------------------------------
# Scale: the inner 4K content rectangle (6336 × 2688) is modelled at ~3 km
# across. For the v5 map this IS the entire working raster, so WORLD_WIDTH_M
# equals INNER_CONTENT_WIDTH_M.
INNER_CONTENT_WIDTH_PX = 6336  # from mapmeta.json
INNER_CONTENT_WIDTH_M = 3000.0
METERS_PER_PIXEL = INNER_CONTENT_WIDTH_M / INNER_CONTENT_WIDTH_PX  # ~0.474 m/px
WORLD_WIDTH_M = IMG_W * METERS_PER_PIXEL  # ~3000 m on v5; ~4830 m on v2-v4

# Vertical exaggeration: 1100 → 275 (1/4) → 412 (1.5×) → 500 (Gary's call,
# ridge-top base now reads dramatically enough).
PEAK_ALT_M = 500.0
RIVER_ALT_M = 0.0

# --- Depth Anything V2 -----------------------------------------------------
DEPTH_MODEL_ID = "depth-anything/Depth-Anything-V2-Base-hf"
DEPTH_DEVICE = "mps"
# Heightmap for the viewer mesh (downsampled from full-res inference).
DEPTH_OUT_W, DEPTH_OUT_H = 1280, 674

# --- Viewer texture --------------------------------------------------------
# The expanded JPG is ~10 MB; we drape it as-is (three.js handles JPG fine).
VIEWER_TEXTURE_LONG_EDGE_PX = 4096  # downsample for browser memory + transfer

# --- Marble API ------------------------------------------------------------
MARBLE_BASE = "https://api.worldlabs.ai/marble/v1"
MARBLE_MODEL = "marble-1.1"
WLT_KEY_FILE = Path.home() / ".config" / "worldlabs" / "api_key"
