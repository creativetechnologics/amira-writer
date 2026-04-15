#!/bin/bash
set -euo pipefail

# End-to-end 3D map pipeline (v2, expanded-map only).
cd "$(dirname "$0")"

PY=${PY:-/opt/miniconda3/bin/python3}

echo "=== Phase A: Depth Anything V2 heightmap ==="
$PY 01_depth_anything.py

echo "=== Phase B: Water segmentation (HSV) ==="
$PY 02_segment_water.py

echo "=== Phase C: Building detection (heightmap bumps) ==="
$PY 03_segment_buildings.py

echo "=== Phase D: Road vectorization ==="
$PY 04_segment_roads.py

echo "=== Phase E: Landmark tagging ==="
$PY 05_tag_landmarks.py

echo "=== Phase F: Compose scene ==="
$PY 06_compose_scene.py

echo
echo "Pipeline complete. Viewer assets live in viewer/"
echo "Start the viewer with:"
echo "  $PY -m http.server 8787 --bind 0.0.0.0 --directory viewer"
echo "Then open: http://Garys-Server.local:8787/"
