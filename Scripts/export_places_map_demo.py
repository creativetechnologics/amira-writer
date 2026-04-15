#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from Scripts.places_master_map_layers import bootstrap_layers

PROJECT = Path('/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera')
REPO = REPO
DEMO_DIR = REPO / 'demos' / 'amira-world-map-demo'
PUBLIC_DIR = DEMO_DIR / 'public'
DATA_DIR = PUBLIC_DIR / 'data'
ASSET_DIR = PUBLIC_DIR / 'assets'
ARTIFACT_DIR = PUBLIC_DIR / 'artifacts'
LEGACY_MASTER_MAP = PROJECT / 'Animate' / 'backgrounds' / 'chosen-references' / 'map' / '01-master_valley_topdown_map_4k_v5.png'
EXPANDED_MASTER_MAP = PROJECT / 'Animate' / 'backgrounds' / 'chosen-references' / 'map' / '02-master_valley_topdown_map_expanded_2026-04-14.jpg'
LAYERS_JSON = PROJECT / 'Animate' / 'places-master-map-layers.json'
WORKFLOW_JSON = PROJECT / 'Animate' / 'places-workflow.json'
PLACES_JSON = PROJECT / 'Animate' / 'places.json'
PIPELINE_3D_WORK = REPO / 'Scripts' / '3d-map-pipeline' / 'work'
PIPELINE_3D_VIEWER = REPO / 'Scripts' / '3d-map-pipeline' / 'viewer'
DEMO_CAPTURE_FILES = (
    REPO / 'amira-world-map-demo-fixed-river.png',
    REPO / 'amira-world-map-demo.png',
    REPO / 'world-map-demo.png',
)

WEST, EAST, SOUTH, NORTH = -100.0, 100.0, -42.4242, 42.4242


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n')


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def path_to_public_url(path: Path) -> str:
    relative = path.relative_to(PUBLIC_DIR).as_posix()
    return f'./{relative}'


def copy_public_artifact(source: Path, target_relative: Path) -> str:
    target = PUBLIC_DIR / target_relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return path_to_public_url(target)


def format_stamp(stamp: str) -> str:
    try:
        dt = datetime.strptime(stamp, '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
        return dt.isoformat().replace('+00:00', 'Z')
    except ValueError:
        return stamp


def collect_3d_pipeline_artifacts() -> list[dict[str, Any]]:
    """Surface the 3D-map-pipeline outputs (Scripts/3d-map-pipeline/work)
    as a demo artifact card. Replaces the old Gemini segmentation pack."""
    if not PIPELINE_3D_WORK.exists():
        return []

    meta_path = PIPELINE_3D_WORK / 'heightmap_meta.json'
    if not meta_path.exists():
        return []
    meta = load_json(meta_path)

    target_root = Path('artifacts') / '3d-map-pipeline'
    previews: list[dict[str, Any]] = []
    for title, file_name in (
        ('Heightmap (quicklook)', 'heightmap_norm.png'),
        ('Water segmentation overlay', 'water_debug.png'),
        ('Water binary mask', 'water_mask.png'),
    ):
        source = PIPELINE_3D_WORK / file_name
        if source.exists():
            previews.append({
                'title': title,
                'url': copy_public_artifact(source, target_root / file_name),
            })

    # Include the composed viewer texture if present.
    texture_src = PIPELINE_3D_VIEWER / 'texture.jpg'
    if texture_src.exists():
        previews.append({
            'title': 'Composed texture drape',
            'url': copy_public_artifact(texture_src, target_root / 'texture.jpg'),
        })

    stats = [
        {'label': 'Working resolution', 'value': f"{meta['working_resolution'][0]}×{meta['working_resolution'][1]}"},
        {'label': 'Metres per pixel', 'value': round(meta['meters_per_pixel'], 3)},
        {'label': 'Peak altitude (m)', 'value': int(meta['peak_alt_m'])},
        {'label': 'River altitude (m)', 'value': int(meta['river_alt_m'])},
        {'label': 'DA V2 scale', 'value': round(meta['anchor']['scale'], 2)},
    ]
    mtime = meta_path.stat().st_mtime
    timestamp = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat().replace('+00:00', 'Z')

    return [{
        'id': '3d-map-pipeline-latest',
        'category': '3D Map Pipeline',
        'kind': 'pipeline',
        'title': 'Depth + water pass',
        'timestamp': timestamp,
        'status': 'terrain + water (SAM2 buildings pending)',
        'summary': f"Depth Anything V2 Base · peak {int(meta['peak_alt_m'])} m · "
                   f"{meta['working_resolution'][0]}×{meta['working_resolution'][1]}",
        'sourcePath': str(PIPELINE_3D_WORK),
        'previews': previews,
        'stats': stats,
    }]


def collect_demo_capture_artifacts(limit: int = 8) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for source in DEMO_CAPTURE_FILES[:limit]:
        if not source.exists():
            continue
        target_relative = Path('artifacts') / 'demo-captures' / source.name
        copied_url = copy_public_artifact(source, target_relative)
        timestamp = datetime.fromtimestamp(source.stat().st_mtime, tz=timezone.utc).isoformat().replace('+00:00', 'Z')
        artifacts.append({
            'id': f'demo-capture-{source.stem}',
            'category': 'Browser Capture',
            'kind': 'capture',
            'title': source.stem.replace('-', ' ').replace('_', ' ').title(),
            'timestamp': timestamp,
            'status': 'snapshot',
            'summary': f'Captured browser output: {source.name}',
            'sourcePath': str(source),
            'previews': [{
                'title': source.name,
                'url': copied_url,
            }],
            'stats': [],
        })
    return artifacts


def collect_artifacts() -> list[dict[str, Any]]:
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    items = [*collect_3d_pipeline_artifacts(), *collect_demo_capture_artifacts()]
    return sorted(items, key=lambda item: item.get('timestamp') or '', reverse=True)


def norm_to_lonlat(x: float, y: float) -> tuple[float, float]:
    lon = WEST + (EAST - WEST) * x
    lat = NORTH - (NORTH - SOUTH) * y
    return lon, lat


def approx_polygon(x: float, y: float, width: float, height: float) -> list[list[float]]:
    corners = [
        (x - width / 2, y - height / 2),
        (x + width / 2, y - height / 2),
        (x + width / 2, y + height / 2),
        (x - width / 2, y + height / 2),
        (x - width / 2, y - height / 2),
    ]
    return [[*norm_to_lonlat(cx, cy)] for cx, cy in corners]


def line_coords(points: list[dict[str, float]]) -> list[list[float]]:
    return [[*norm_to_lonlat(float(point['x']), float(point['y']))] for point in points]


def polygon_coords(points: list[dict[str, float]]) -> list[list[list[float]]]:
    return [line_coords(points)]


def workflow_master_map(workflow: dict[str, Any]) -> Path:
    explicit = workflow.get('masterMapImagePath')
    if explicit:
        candidate = PROJECT / str(explicit)
        if candidate.exists():
            return candidate
    if LEGACY_MASTER_MAP.exists():
        return LEGACY_MASTER_MAP
    return EXPANDED_MASTER_MAP


def demo_master_map(workflow: dict[str, Any]) -> Path:
    if EXPANDED_MASTER_MAP.exists():
        return EXPANDED_MASTER_MAP
    return workflow_master_map(workflow)


def map_meta_path(image_path: Path) -> Path:
    return image_path.with_suffix('.mapmeta.json')


def image_coordinates_from_meta(image_path: Path) -> list[list[float]]:
    meta_path = map_meta_path(image_path)
    if not meta_path.exists():
        return [[WEST, NORTH], [EAST, NORTH], [EAST, SOUTH], [WEST, SOUTH]]

    meta = load_json(meta_path)
    rect = (meta.get('logicalContentRectNormalized') or {})
    try:
        left = float(rect['x'])
        top = float(rect['y'])
        width = float(rect['width'])
        height = float(rect['height'])
    except (KeyError, TypeError, ValueError):
        return [[WEST, NORTH], [EAST, NORTH], [EAST, SOUTH], [WEST, SOUTH]]

    right = left + width
    bottom = top + height
    lon_span = EAST - WEST
    lat_span = NORTH - SOUTH
    full_west = WEST - (left / width) * lon_span
    full_east = EAST + ((1 - right) / width) * lon_span
    full_north = NORTH + (top / height) * lat_span
    full_south = SOUTH - ((1 - bottom) / height) * lat_span
    return [
        [round(full_west, 6), round(full_north, 6)],
        [round(full_east, 6), round(full_north, 6)],
        [round(full_east, 6), round(full_south, 6)],
        [round(full_west, 6), round(full_south, 6)],
    ]


def export() -> None:
    PUBLIC_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)

    workflow = load_json(WORKFLOW_JSON)
    bootstrap_layers(PROJECT)
    layers = load_json(LAYERS_JSON) if LAYERS_JSON.exists() else {'layers': {}}
    places = load_json(PLACES_JSON)
    demo_map = demo_master_map(workflow)

    image_target = ASSET_DIR / demo_map.name
    shutil.copy2(demo_map, image_target)

    places_by_id = {p.get('id'): p for p in places if p.get('id')}
    layers_obj = layers.get('layers', {})
    landmarks = layers_obj.get('landmarks', [])
    buildings = layers_obj.get('buildings', [])
    roads = layers_obj.get('roads', [])
    water = layers_obj.get('water', [])
    bridges = layers_obj.get('bridges', [])

    pin_features = []
    for record in workflow.get('generatedImageRecords') or []:
        if record.get('mapPlacementStatus') != 'confirmed':
            continue
        if record.get('isRejected'):
            continue
        point = record.get('mapPoint') or {}
        if point.get('x') is None or point.get('y') is None:
            continue
        lon, lat = norm_to_lonlat(float(point['x']), float(point['y']))
        pin_features.append({
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [lon, lat]},
            'properties': {
                'id': record.get('id'),
                'title': Path(record.get('activePath') or '').name,
                'placeName': record.get('linkedPlaceName') or (places_by_id.get(record.get('linkedPlaceID')) or {}).get('name'),
                'imagePath': record.get('activePath'),
                'rating': record.get('rating') or 0,
            }
        })

    building_features = []
    default_dims = {
        'clinic': (0.030, 0.020, 18),
        'amira_home': (0.022, 0.016, 11),
        'gathering_space': (0.032, 0.024, 14),
        'marketplace': (0.040, 0.028, 12),
    }
    for item in buildings:
        x = item.get('anchorX')
        y = item.get('anchorY')
        if x is None or y is None:
            continue
        kind = item.get('kind') or 'custom'
        w, h, z = default_dims.get(kind, (0.020, 0.014, 10))
        coords = [approx_polygon(float(x), float(y), w, h)]
        building_features.append({
            'type': 'Feature',
            'geometry': {'type': 'Polygon', 'coordinates': coords},
            'properties': {
                'title': item.get('title'),
                'kind': kind,
                'height': item.get('heightMeters') or z,
                'base': 0,
            }
        })

    road_features = []
    for road in roads:
        points = road.get('points') or []
        if len(points) < 2:
            continue
        road_features.append({
            'type': 'Feature',
            'geometry': {'type': 'LineString', 'coordinates': line_coords(points)},
            'properties': {
                'id': road.get('id'),
                'title': road.get('title'),
                'kind': road.get('kind'),
                'source': road.get('source'),
                'draft': bool(road.get('draft')),
                'fromAnchorKey': road.get('fromAnchorKey'),
                'toAnchorKey': road.get('toAnchorKey'),
            }
        })

    water_features = []
    for feature in water:
        polygon = feature.get('polygon') or []
        if len(polygon) < 4:
            continue
        water_features.append({
            'type': 'Feature',
            'geometry': {'type': 'Polygon', 'coordinates': polygon_coords(polygon)},
            'properties': {
                'id': feature.get('id'),
                'title': feature.get('title'),
                'kind': feature.get('kind'),
                'source': feature.get('source'),
                'draft': bool(feature.get('draft')),
            }
        })

    bridge_features = []
    for feature in bridges:
        footprint = feature.get('footprint') or []
        if len(footprint) < 4:
            continue
        bridge_features.append({
            'type': 'Feature',
            'geometry': {'type': 'Polygon', 'coordinates': polygon_coords(footprint)},
            'properties': {
                'id': feature.get('id'),
                'title': feature.get('title'),
                'kind': feature.get('kind'),
                'source': feature.get('source'),
                'draft': bool(feature.get('draft')),
                'linkedWaterID': feature.get('linkedWaterID'),
                'linkedRoadIDs': ', '.join(feature.get('linkedRoadIDs') or []),
            }
        })

    landmark_features = []
    for landmark in landmarks:
        if 'x' not in landmark or 'y' not in landmark:
            continue
        lon, lat = norm_to_lonlat(float(landmark['x']), float(landmark['y']))
        landmark_features.append({
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [lon, lat]},
            'properties': {
                'title': landmark.get('title'),
                'kind': landmark.get('kind'),
                'source': landmark.get('source'),
            }
        })

    payload = {
        'updatedAt': iso_now(),
        'image': {
            'url': path_to_public_url(image_target),
            'coordinates': image_coordinates_from_meta(demo_map),
            'sourcePath': str(demo_map),
            'logicalContentSourcePath': str(workflow_master_map(workflow)),
        },
        'bounds': {'west': WEST, 'east': EAST, 'south': SOUTH, 'north': NORTH},
        'roads': {'type': 'FeatureCollection', 'features': road_features},
        'water': {'type': 'FeatureCollection', 'features': water_features},
        'bridges': {'type': 'FeatureCollection', 'features': bridge_features},
        'buildings': {'type': 'FeatureCollection', 'features': building_features},
        'landmarks': {'type': 'FeatureCollection', 'features': landmark_features},
        'pins': {'type': 'FeatureCollection', 'features': pin_features},
        'artifacts': collect_artifacts(),
    }
    save_json(DATA_DIR / 'world-map-demo.json', payload)
    print(DATA_DIR / 'world-map-demo.json')


if __name__ == '__main__':
    export()
