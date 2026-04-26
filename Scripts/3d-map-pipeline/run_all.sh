#!/bin/bash
set -euo pipefail

# End-to-end 3D map pipeline.
#
# Default run is "terrain only" — Phases A (depth), B (water), F (compose).
# Building / road / landmark detection (Phases C, D, E) are skipped because
# the SAM2 building detector takes 30+ minutes on M-series MPS and produces
# unreliable footprints on illustrated/painted maps. Re-enable them by
# exporting WITH_BUILDINGS=1 before invoking this script.
cd "$(dirname "$0")"

PY=${PY:-/opt/miniconda3/bin/python3}
WITH_BUILDINGS=${WITH_BUILDINGS:-0}

echo "=== Phase A: Depth Anything V2 heightmap ==="
$PY 01_depth_anything.py

echo "=== Phase B: Water segmentation (HSV) ==="
$PY 02_segment_water.py

if [[ "$WITH_BUILDINGS" == "1" ]]; then
    echo "=== Phase C: Building detection (SAM 2) ==="
    $PY 03_segment_buildings.py

    echo "=== Phase D: Road vectorization ==="
    $PY 04_segment_roads.py

    echo "=== Phase E: Landmark tagging ==="
    $PY 05_tag_landmarks.py
else
    echo "=== Phases C/D/E skipped (set WITH_BUILDINGS=1 to enable) ==="
    # Drop any stale building/road geojson so Phase F doesn't re-emit
    # outdated footprints from a prior run against a different master map.
    rm -f work/buildings.geojson work/buildings_tagged.geojson
    rm -f work/buildings_debug.png
    rm -f work/roads.geojson work/roads_debug.png
fi

echo "=== Phase F: Compose scene ==="
$PY 06_compose_scene.py

echo
echo "Pipeline complete. Viewer assets live in viewer/"
echo "Start the viewer with:"
echo "  $PY -m http.server 8787 --bind 0.0.0.0 --directory viewer"
echo "Then open: http://Garys-Server.local:8787/"
