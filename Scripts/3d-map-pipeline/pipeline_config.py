"""Central config for the 3D map pipeline (v2 — expanded map, no Gemini deps).

One place to change paths, metric anchors, and tunables. All scripts import this.
"""
from __future__ import annotations
from pathlib import Path

# --- Input -----------------------------------------------------------------
# The canonical 10200 × 5380 expanded master map. Everything in this pipeline
# runs on this image directly — no upstream segmentation pack required.
ASSETS_ROOT = Path(
    "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate"
)
# V4 (2026-04-14 Amira Satellite Map V4): latest iteration from Gary.
# Same 10200 × 5380 dimensions as prior expanded maps.
EXPANDED_MAP = (
    ASSETS_ROOT
    / "backgrounds/chosen-references/map/04-master_valley_topdown_map_amira-sat-v4_2026-04-14.jpg"
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
IMG_W, IMG_H = 10200, 5380

# --- Metric anchors --------------------------------------------------------
# Scale: the inner 4K content rectangle (6336 × 2688 of these expanded pixels)
# was previously modelled at ~3 km across. Keep that constant, so the
# expanded image spans ~4.8 km end-to-end.
INNER_CONTENT_WIDTH_PX = 6336  # from mapmeta.json
INNER_CONTENT_WIDTH_M = 3000.0
METERS_PER_PIXEL = INNER_CONTENT_WIDTH_M / INNER_CONTENT_WIDTH_PX  # ~0.474 m/px
WORLD_WIDTH_M = IMG_W * METERS_PER_PIXEL  # ~4830 m

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
