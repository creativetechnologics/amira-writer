# Places Master Map Vectorization / 3D Roadmap

## Goal
Turn the Amira master map from a flat reference image into a structured world-map asset with reusable layers:
- landmark anchors
- building anchors / footprints
- roads / walk paths
- river / water boundaries
- bridge axis / footprint
- district polygons

This is the foundation for:
- better automatic pin placement
- indoor/outdoor landmark linkage
- future 3D-ish map rendering
- later Marble / Gaussian-splat / Unreal scouting work

## Practical conclusion
A fictional painted “satellite” map should **not** be treated like a real GIS raster that can be perfectly auto-vectorized in one shot.

The best practical path is a **semi-automatic constraint pipeline**:
1. georeference / normalize the master map
2. segment major structures into masks
3. polygonize masks into vectors
4. store vectors as project-local map layers
5. render / edit those layers in-app
6. use those layers as constraints for placement and generation

## What current tooling supports

### 1) QGIS + GDAL are the right foundation for raster → vector conversion
QGIS exposes GDAL’s official `Polygonize (raster to vector)` algorithm, which creates vector polygons for connected raster regions that share a pixel value. That gives us a reliable official path from segmentation masks to editable vector polygons.

### 2) MapLibre-style map rendering already has the right rendering vocabulary
MapLibre’s style spec supports:
- raster layers for the painted master map base
- line / fill / symbol layers for road and landmark overlays
- `fill-extrusion-height` for 3D building extrusion semantics

Even if we do not adopt MapLibre directly inside the Swift app right away, its layering model is the correct mental model for our own renderer.

### 3) World Labs Marble is useful later, not as the primary truth system
World Labs’ current API/docs support worlds from:
- text
- one image
- multiple images of the same scene
- video

and returns splat + mesh + pano assets.

That makes Marble strong for:
- scouting
- rough explorable blocking
- camera exploration / previs

But it should remain downstream of the canon map + canon images, not replace them.

## Recommended phases

### Phase 0 — already started
- keep the painted master map as the canonical raster base
- use confirmed pins and landmark anchors as truth
- store project-local layer scaffolds in JSON/GeoJSON

### Phase 1 — structured 2D layer bundle
Create project-local layers:
- `landmarks`
- `buildings`
- `roads`
- `water`
- `bridges`
- `districts`

Use the new headless scaffold file:
- `Animate/places-master-map-layers.json`

### Phase 2 — semi-automatic vectorization
For each class (river, bridge, roads, settlement blocks):
1. make a mask from the master map
2. refine manually where needed
3. polygonize into vector geometry
4. simplify / smooth geometry
5. persist as map layers

### Phase 3 — in-app vector overlays
Render vector layers over the raster map and use them to:
- constrain pin placement
- reject impossible placements (river, off-road, wrong bank)
- cluster interiors under building anchors

### Phase 4 — pseudo-3D building rendering
Use building footprints + height metadata to render lightweight extrusions in the existing map pane.
This gets us most of the “Google Earth” feeling before full 3D scene integration.

### Phase 5 — optional Marble / splat scouting
Feed canon images into Marble only after the 2D map truth is stable.
Use Marble for:
- camera scouting
- rough line-of-sight checks
- previs / exploratory navigation

## What I implemented this round
- Landmarks workflow in-app (compile + deploy)
- headless landmark/building anchor repair from the latest user pin placements
- new headless scaffold generator:
  - `Scripts/places_master_map_layers.py`
- live scaffold output:
  - `Animate/places-master-map-layers.json`
- authoritative anchor priority now prefers fresh `worldGraph.node` landmarks over stale confirmed-image placements when deriving shared map vectors
- draft shared vector layers now auto-refresh into `roads`, `water`, and `bridges`, so the layer JSON and the browser demo use the same structured map truth

## Current limitation
The new layer scaffold is not a finished vectorized town yet. It is the correct durable starting point for getting there.

## Official references
- QGIS GDAL raster conversion / Polygonize: https://docs.qgis.org/3.44/en/docs/user_manual/processing_algs/gdal/rasterconversion.html
- MapLibre layer spec / raster / line / fill-extrusion: https://maplibre.org/maplibre-style-spec/layers/
- World Labs API quickstart / world generation outputs: https://docs.worldlabs.ai/api
