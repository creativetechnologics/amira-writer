#!/usr/bin/env python3
"""Bootstrap and inspect project-local master-map vector layer scaffolds.

This is a headless helper for turning the fictional Amira master map into a more
structured map asset over time. It does not magically vectorize the image; it
creates a durable project-local layer bundle that can accumulate:
- landmark/building anchors
- river / road / bridge / district vectors
- future manual or semi-automatic polygon traces
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_PROJECT = Path('/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera')
MASTER_MAP_FALLBACK = 'Animate/backgrounds/chosen-references/map/01-master_valley_topdown_map_4k_v5.png'
LAYERS_FILE = 'Places/places-master-map-layers.json'
AUTO_ANCHOR_SOURCES = {'worldGraph.node', 'generatedRecord.confirmed'}
AUTO_VECTOR_SOURCE_PREFIXES = ('draft.',)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def save_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + '\n')


def workflow_path(project: Path) -> Path:
    return project / 'Places' / 'places-workflow.json'


def places_path(project: Path) -> Path:
    return project / 'Places' / 'places.json'


def output_path(project: Path) -> Path:
    return project / LAYERS_FILE


def clean(text: str | None) -> str:
    return (text or '').strip()


def lower(text: str | None) -> str:
    return clean(text).lower()


def effective_master_map(workflow: dict[str, Any]) -> str:
    if workflow.get('masterMapImagePath'):
        return workflow['masterMapImagePath']
    return MASTER_MAP_FALLBACK


def landmark_kind(name: str) -> str | None:
    l = lower(name)
    if 'amira' in l and 'home' in l:
        return 'amira_home'
    if 'bridge' in l:
        return 'bridge'
    if 'clinic' in l:
        return 'clinic'
    if 'gathering' in l:
        return 'gathering_space'
    if 'market' in l:
        return 'marketplace'
    if 'grave' in l or 'memorial' in l:
        return 'memorial'
    if 'river' in l and 'bridge' not in l:
        return 'riverside'
    if 'ridge' in l or 'mountain valley' in l:
        return 'ridge'
    return None


def empty_layers(master_map_path: str) -> dict[str, Any]:
    return {
        'schemaVersion': 2,
        'updatedAt': now_iso(),
        'masterMapPath': master_map_path,
        'layers': {
            'landmarks': [],
            'roads': [],
            'water': [],
            'bridges': [],
            'districts': [],
            'buildings': []
        }
    }


def upsert_feature(features: list[dict[str, Any]], feature: dict[str, Any], key: str = 'id') -> None:
    feature_id = feature.get(key)
    for index, existing in enumerate(features):
        if existing.get(key) == feature_id:
            features[index] = feature
            return
    features.append(feature)


def normalize01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def point_dict(x: float, y: float) -> dict[str, float]:
    return {'x': round(normalize01(x), 6), 'y': round(normalize01(y), 6)}


def source_priority(source: str | None) -> int:
    source = source or ''
    if source.startswith('manual') or source.startswith('user'):
        return 100
    if source == 'worldGraph.node':
        return 80
    if source == 'generatedRecord.confirmed':
        return 40
    return 10


def anchor_aliases(feature: dict[str, Any]) -> set[str]:
    aliases: set[str] = set()
    title = lower(feature.get('title'))
    kind = lower(feature.get('kind'))
    if kind:
        aliases.add(kind)
    if 'clinic' in title:
        aliases.add('clinic')
    if 'gathering' in title:
        aliases.add('gathering_space')
    if 'amira' in title and 'home' in title:
        aliases.add('amira_home')
    if 'bridge' in title:
        aliases.add('bridge')
    if 'river' in title and 'bridge' not in title:
        aliases.add('riverside')
    if 'ridge' in title:
        aliases.add('ridge')
    if feature.get('placeID'):
        aliases.add(str(feature['placeID']).lower())
    return aliases


def authoritative_anchor_map(landmarks: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    anchors: dict[str, dict[str, Any]] = {}
    for landmark in landmarks:
        if landmark.get('x') is None or landmark.get('y') is None:
            continue
        priority = source_priority(landmark.get('source'))
        candidate = {
            'id': landmark.get('id'),
            'title': landmark.get('title'),
            'kind': landmark.get('kind'),
            'x': float(landmark['x']),
            'y': float(landmark['y']),
            'source': landmark.get('source'),
            'placeID': landmark.get('placeID'),
            '_priority': priority,
        }
        for alias in anchor_aliases(landmark):
            existing = anchors.get(alias)
            if existing is None or priority > existing['_priority']:
                anchors[alias] = candidate
    for alias, candidate in list(anchors.items()):
        anchors[alias] = {k: v for k, v in candidate.items() if not k.startswith('_')}
    return anchors


def _load_image_stack():
    import numpy as np
    from PIL import Image
    from scipy.ndimage import gaussian_filter

    return np, Image, gaussian_filter


def build_cost_map(image: Any, scale: float = 0.22, mode: str = 'road'):
    np, _, gaussian_filter = _load_image_stack()
    small = image.resize((max(256, int(image.size[0] * scale)), max(128, int(image.size[1] * scale))))
    arr = np.array(small.convert('RGB')).astype(np.float32)
    mx = arr.max(axis=2)
    mn = arr.min(axis=2)
    sat = np.divide(mx - mn, mx, out=np.zeros_like(mx), where=mx > 0)
    gray = arr.mean(axis=2) / 255.0
    blur = gaussian_filter(gray, sigma=2.4 if mode == 'water' else 2.0)
    contrast = np.clip(blur - gray, -1, 1)

    if mode == 'water':
        cost = 0.26 + gray * 1.45 + sat * 0.25 + np.abs(blur - gray) * 0.35
        cost -= np.clip((0.62 - gray), 0, 0.50) * 1.35
        cost -= np.clip((0.16 - sat), 0, 0.16) * 0.60
        cost += np.where(contrast < -0.02, np.abs(contrast) * 0.15, 0)
    else:
        cost = 0.15 + gray * 1.75 + sat * 0.75
        cost += np.where(contrast > 0, -contrast * 1.5, 0.25 * np.abs(contrast))
        cost -= np.clip((0.80 - gray), 0, 0.25) * 0.85

    cost = np.clip(cost, 0.02, 4.5)
    return small, cost


def astar(cost: Any, start: tuple[int, int], goal: tuple[int, int]) -> list[tuple[int, int]]:
    sx, sy = start
    gx, gy = goal
    h, w = cost.shape
    pq: list[tuple[float, int, int]] = [(0.0, sx, sy)]
    gscore = {(sx, sy): 0.0}
    prev: dict[tuple[int, int], tuple[int, int]] = {}
    dirs = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]

    while pq:
        _, x, y = heapq.heappop(pq)
        if (x, y) == (gx, gy):
            break
        base = gscore[(x, y)]
        for dx, dy in dirs:
            nx, ny = x + dx, y + dy
            if not (0 <= nx < w and 0 <= ny < h):
                continue
            step = math.hypot(dx, dy)
            ng = base + step * float(cost[ny, nx])
            if ng < gscore.get((nx, ny), 1e18):
                gscore[(nx, ny)] = ng
                prev[(nx, ny)] = (x, y)
                heuristic = math.hypot(gx - nx, gy - ny) * (0.15 if step > 1 else 0.20)
                heapq.heappush(pq, (ng + heuristic, nx, ny))

    node = (gx, gy)
    if node not in prev and node != (sx, sy):
        return []
    path = [node]
    while node != (sx, sy):
        node = prev[node]
        path.append(node)
    path.reverse()
    return path


def perpendicular_distance(point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]) -> float:
    x0, y0 = point
    x1, y1 = start
    x2, y2 = end
    dx = x2 - x1
    dy = y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x0 - x1, y0 - y1)
    numerator = abs(dy * x0 - dx * y0 + x2 * y1 - y2 * x1)
    denominator = math.hypot(dx, dy)
    return numerator / denominator


def rdp(points: list[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    if len(points) < 3:
        return points
    start = points[0]
    end = points[-1]
    max_dist = -1.0
    index = -1
    for i in range(1, len(points) - 1):
        dist = perpendicular_distance(points[i], start, end)
        if dist > max_dist:
            max_dist = dist
            index = i
    if max_dist > epsilon:
        left = rdp(points[: index + 1], epsilon)
        right = rdp(points[index:], epsilon)
        return left[:-1] + right
    return [start, end]


def dedupe_path(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    deduped: list[tuple[float, float]] = []
    for point in points:
        if not deduped or point != deduped[-1]:
            deduped.append(point)
    return deduped


def normalized_polyline(path: list[tuple[int, int]], width: int, height: int, epsilon: float) -> list[dict[str, float]]:
    norm_points = [(x / (width - 1), y / (height - 1)) for x, y in path]
    simplified = dedupe_path(rdp(norm_points, epsilon=epsilon))
    return [point_dict(x, y) for x, y in simplified]


def remove_auto_features(features: list[dict[str, Any]], id_prefix: str) -> list[dict[str, Any]]:
    filtered: list[dict[str, Any]] = []
    for feature in features:
        source = str(feature.get('source') or '')
        feature_id = str(feature.get('id') or '')
        if source.startswith(AUTO_VECTOR_SOURCE_PREFIXES) or feature_id.startswith(id_prefix):
            continue
        filtered.append(feature)
    return filtered


def clamp_point(point: tuple[float, float]) -> tuple[float, float]:
    return normalize01(point[0]), normalize01(point[1])


def blend_points(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return a[0] * (1 - t) + b[0] * t, a[1] * (1 - t) + b[1] * t


def normalize_vec(dx: float, dy: float) -> tuple[float, float]:
    length = math.hypot(dx, dy)
    if length == 0:
        return 1.0, 0.0
    return dx / length, dy / length


def path_tangent(points: list[dict[str, float]], anchor: tuple[float, float]) -> tuple[float, float]:
    tuples = [(float(point['x']), float(point['y'])) for point in points]
    if len(tuples) < 2:
        return 1.0, 0.0
    distances = [math.hypot(px - anchor[0], py - anchor[1]) for px, py in tuples]
    index = min(range(len(tuples)), key=lambda i: distances[i])
    prev_index = max(0, index - 1)
    next_index = min(len(tuples) - 1, index + 1)
    if prev_index == next_index:
        next_index = min(len(tuples) - 1, index + 1)
    start = tuples[prev_index]
    end = tuples[next_index]
    return normalize_vec(end[0] - start[0], end[1] - start[1])


def make_band_polygon(
    centerline: list[dict[str, float]],
    start_half_width: float,
    end_half_width: float,
) -> list[dict[str, float]]:
    tuples = [(float(point['x']), float(point['y'])) for point in centerline]
    if len(tuples) < 2:
        return []

    left: list[tuple[float, float]] = []
    right: list[tuple[float, float]] = []
    for index, point in enumerate(tuples):
        if index == 0:
            prev_point = point
            next_point = tuples[index + 1]
        elif index == len(tuples) - 1:
            prev_point = tuples[index - 1]
            next_point = point
        else:
            prev_point = tuples[index - 1]
            next_point = tuples[index + 1]
        tangent = normalize_vec(next_point[0] - prev_point[0], next_point[1] - prev_point[1])
        normal = (-tangent[1], tangent[0])
        t = index / max(1, len(tuples) - 1)
        half_width = start_half_width + (end_half_width - start_half_width) * t
        left.append(clamp_point((point[0] + normal[0] * half_width, point[1] + normal[1] * half_width)))
        right.append(clamp_point((point[0] - normal[0] * half_width, point[1] - normal[1] * half_width)))

    polygon = left + list(reversed(right))
    if polygon and polygon[0] != polygon[-1]:
        polygon.append(polygon[0])
    return [point_dict(x, y) for x, y in polygon]


def merge_paths(*segments: list[dict[str, float]]) -> list[dict[str, float]]:
    merged: list[dict[str, float]] = []
    for segment in segments:
        for point in segment:
            if merged and point['x'] == merged[-1]['x'] and point['y'] == merged[-1]['y']:
                continue
            merged.append(point)
    return merged


def water_seed_score(color: tuple[float, float, float]) -> float:
    r, g, b = color
    brightness = (r + g + b) / 3.0
    score = (g + b - 2 * r) - 0.35 * abs(g - b) - 0.18 * abs(brightness - 138.0)
    if brightness < 65 or brightness > 175:
        score -= 20
    return float(score)


def find_best_water_seed(arr: Any, anchor: tuple[float, float], radius: int = 80) -> tuple[tuple[int, int], tuple[float, float, float]]:
    height, width = arr.shape[:2]
    cx = int(anchor[0] * (width - 1))
    cy = int(anchor[1] * (height - 1))
    best_score = -1e18
    best_point = (cx, cy)
    best_color = tuple(float(v) for v in arr[cy, cx])
    for yy in range(max(0, cy - radius), min(height, cy + radius + 1)):
        for xx in range(max(0, cx - radius), min(width, cx + radius + 1)):
            color = tuple(float(v) for v in arr[yy, xx])
            score = water_seed_score(color)
            if score > best_score:
                best_score = score
                best_point = (xx, yy)
                best_color = color
    return best_point, best_color


def build_polygon_from_mask(component: Any, width: int, height: int) -> tuple[list[dict[str, float]], list[dict[str, float]], dict[str, float]] | None:
    import numpy as np
    from scipy.ndimage import gaussian_filter1d

    xs = np.where(component.any(axis=0))[0]
    if len(xs) < 8:
        return None

    top = np.full(xs.shape, np.nan, dtype=np.float32)
    bottom = np.full(xs.shape, np.nan, dtype=np.float32)
    for index, x in enumerate(xs):
        ys = np.where(component[:, x])[0]
        if len(ys) == 0:
            continue
        top[index] = ys.min()
        bottom[index] = ys.max()

    valid = ~np.isnan(top)
    if valid.sum() < 8:
        return None

    top = np.interp(xs, xs[valid], top[valid])
    bottom = np.interp(xs, xs[valid], bottom[valid])
    top = gaussian_filter1d(top, sigma=3.0, mode='nearest')
    bottom = gaussian_filter1d(bottom, sigma=3.0, mode='nearest')

    center = (top + bottom) / 2.0
    polygon_top = [point_dict(x / (width - 1), float(y) / (height - 1)) for x, y in zip(xs, top)]
    polygon_bottom = [point_dict(x / (width - 1), float(y) / (height - 1)) for x, y in zip(reversed(xs), reversed(bottom))]
    polygon = polygon_top + polygon_bottom
    if polygon and polygon[0] != polygon[-1]:
        polygon.append(polygon[0])

    centerline_points = [(float(x) / (width - 1), float(y) / (height - 1)) for x, y in zip(xs, center)]
    centerline = [point_dict(x, y) for x, y in dedupe_path(rdp(centerline_points, epsilon=0.0012))]

    widths = ((bottom - top) / max(1, height - 1)).astype(np.float32)
    diagnostics = {
        'minX': float(xs.min() / (width - 1)),
        'maxX': float(xs.max() / (width - 1)),
        'avgHalfWidth': float(widths.mean() / 2.0),
    }
    return centerline, polygon, diagnostics


def extract_river_geometry(image: Any, bridge_anchor: tuple[float, float], riverside_anchor: tuple[float, float]) -> tuple[list[dict[str, float]], list[dict[str, float]], dict[str, float]] | None:
    import numpy as np
    from scipy import ndimage

    scale = 0.22
    small = image.resize((max(256, int(image.size[0] * scale)), max(128, int(image.size[1] * scale))))
    arr = np.array(small.convert('RGB')).astype(np.float32)
    height, width = arr.shape[:2]

    bridge_seed, bridge_color = find_best_water_seed(arr, bridge_anchor)
    riverside_seed, riverside_color = find_best_water_seed(arr, riverside_anchor)
    target = np.mean(np.array([bridge_color, riverside_color], dtype=np.float32), axis=0)

    r, g, b = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2]
    brightness = arr.mean(axis=2)
    dist = np.linalg.norm(arr - target, axis=2)
    mask = (
        (dist < 34.0)
        & (((g + b) / 2.0 - r) > -5.0)
        & (brightness > 65.0)
        & (brightness < 175.0)
    )
    mask = ndimage.binary_opening(mask, structure=np.ones((2, 2), dtype=bool))

    y_values = [bridge_seed[1], riverside_seed[1]]
    y0 = max(0, min(y_values) - max(70, int(height * 0.12)))
    y1 = min(height, max(y_values) + max(70, int(height * 0.12)))
    band_mask = np.zeros_like(mask)
    band_mask[y0:y1, :] = mask[y0:y1, :]

    close_width = max(121, int(width * 0.16))
    band_mask = ndimage.binary_closing(band_mask, structure=np.ones((5, close_width), dtype=bool))
    band_mask = ndimage.binary_opening(band_mask, structure=np.ones((2, 3), dtype=bool))
    band_mask = ndimage.binary_dilation(band_mask, structure=np.ones((2, 7), dtype=bool))

    labels, _ = ndimage.label(band_mask)
    seed_labels = {
        int(labels[bridge_seed[1], bridge_seed[0]]),
        int(labels[riverside_seed[1], riverside_seed[0]]),
    } - {0}
    if seed_labels:
        component = np.isin(labels, list(seed_labels))
    else:
        areas = ndimage.sum(band_mask, labels, index=range(1, labels.max() + 1))
        if len(areas) == 0:
            return None
        best_label = int(np.argmax(areas)) + 1
        component = labels == best_label

    return build_polygon_from_mask(component, width, height)


def sync_draft_vectors(payload: dict[str, Any], project: Path) -> None:
    layers = payload.setdefault('layers', {})
    landmarks = layers.setdefault('landmarks', [])
    roads = layers.setdefault('roads', [])
    water = layers.setdefault('water', [])
    bridges = layers.setdefault('bridges', [])
    anchors = authoritative_anchor_map(landmarks)

    master_map_path = project / str(payload.get('masterMapPath') or MASTER_MAP_FALLBACK)
    if not master_map_path.exists() or not anchors:
        return

    _, Image, _ = _load_image_stack()
    image = Image.open(master_map_path)
    road_small, road_cost = build_cost_map(image, scale=0.22, mode='road')
    road_width, road_height = road_small.size

    def to_px(point: tuple[float, float], width: int, height: int) -> tuple[int, int]:
        return int(point[0] * (width - 1)), int(point[1] * (height - 1))

    road_specs = [
        ('ridge', 'bridge', 'Ridge road descent', 'ridge_road'),
        ('bridge', 'gathering_space', 'Bridge to gathering space', 'village_path'),
        ('gathering_space', 'amira_home', 'Gathering space to Amira home', 'village_path'),
        ('amira_home', 'clinic', 'Amira home to clinic', 'village_path'),
    ]

    manual_roads = remove_auto_features(roads, 'road::draft::')
    draft_roads: list[dict[str, Any]] = []
    for start_key, end_key, title, kind in road_specs:
        if start_key not in anchors or end_key not in anchors:
            continue
        start = (anchors[start_key]['x'], anchors[start_key]['y'])
        end = (anchors[end_key]['x'], anchors[end_key]['y'])
        path = astar(road_cost, to_px(start, road_width, road_height), to_px(end, road_width, road_height))
        if not path:
            continue
        epsilon = 0.0008 if len(path) > 140 else 0.0010
        points = normalized_polyline(path, road_width, road_height, epsilon=epsilon)
        if len(points) < 2:
            continue
        draft_roads.append({
            'id': f'road::draft::{start_key}::{end_key}',
            'title': title,
            'kind': kind,
            'source': 'draft.anchor_path',
            'draft': True,
            'fromAnchorKey': start_key,
            'toAnchorKey': end_key,
            'points': points,
        })
    roads[:] = manual_roads + draft_roads

    manual_water = remove_auto_features(water, 'water::draft::')
    draft_water: list[dict[str, Any]] = []
    water_item: dict[str, Any] | None = None
    if 'bridge' in anchors and 'riverside' in anchors:
        bridge = (anchors['bridge']['x'], anchors['bridge']['y'])
        riverside = (anchors['riverside']['x'], anchors['riverside']['y'])
        extracted = extract_river_geometry(image, bridge, riverside)
        if extracted:
            centerline, polygon, diagnostics = extracted
            water_item = {
                'id': 'water::draft::main-river',
                'title': 'Main River',
                'kind': 'river',
                'source': 'draft.color_mask_from_master_map',
                'draft': True,
                'centerline': centerline,
                'polygon': polygon,
                'bridgeHalfWidth': diagnostics.get('avgHalfWidth', 0.013),
                'maskSpan': {
                    'minX': diagnostics.get('minX'),
                    'maxX': diagnostics.get('maxX'),
                },
            }
            draft_water.append(water_item)
    water[:] = manual_water + draft_water

    manual_bridges = remove_auto_features(bridges, 'bridge::draft::')
    draft_bridges: list[dict[str, Any]] = []
    if 'bridge' in anchors:
        bridge_center = (anchors['bridge']['x'], anchors['bridge']['y'])
        tangent = None
        preferred_road_ids = [
            'road::draft::ridge::bridge',
            'road::draft::bridge::gathering_space',
        ]
        for road in roads:
            if road.get('id') in preferred_road_ids and road.get('points'):
                tangent = path_tangent(road['points'], bridge_center)
                break
        if tangent is None and 'gathering_space' in anchors:
            tangent = normalize_vec(anchors['gathering_space']['x'] - bridge_center[0], anchors['gathering_space']['y'] - bridge_center[1])
        if tangent is None:
            tangent = (1.0, 0.0)

        river_half_width = float((water_item or {}).get('bridgeHalfWidth') or 0.013)

        bridge_length = max(0.016, river_half_width * 2.2)
        bridge_width = 0.0036
        normal = (-tangent[1], tangent[0])
        a = clamp_point((bridge_center[0] - tangent[0] * bridge_length / 2, bridge_center[1] - tangent[1] * bridge_length / 2))
        b = clamp_point((bridge_center[0] + tangent[0] * bridge_length / 2, bridge_center[1] + tangent[1] * bridge_length / 2))
        footprint = [
            clamp_point((a[0] + normal[0] * bridge_width, a[1] + normal[1] * bridge_width)),
            clamp_point((b[0] + normal[0] * bridge_width, b[1] + normal[1] * bridge_width)),
            clamp_point((b[0] - normal[0] * bridge_width, b[1] - normal[1] * bridge_width)),
            clamp_point((a[0] - normal[0] * bridge_width, a[1] - normal[1] * bridge_width)),
            clamp_point((a[0] + normal[0] * bridge_width, a[1] + normal[1] * bridge_width)),
        ]
        draft_bridges.append({
            'id': 'bridge::draft::old-stone-bridge',
            'title': 'Old Stone Bridge',
            'kind': 'bridge',
            'source': 'draft.road_span',
            'draft': True,
            'linkedRoadIDs': [road['id'] for road in roads if 'bridge' in str(road.get('id') or '')],
            'linkedWaterID': water_item.get('id') if water_item else None,
            'centerline': [point_dict(*a), point_dict(*b)],
            'footprint': [point_dict(x, y) for x, y in footprint],
            'x': round(bridge_center[0], 6),
            'y': round(bridge_center[1], 6),
        })
    bridges[:] = manual_bridges + draft_bridges


def bootstrap_layers(project: Path, overwrite: bool = False) -> Path:
    workflow = load_json(workflow_path(project))
    places = load_json(places_path(project))
    out = output_path(project)
    if out.exists() and not overwrite:
        payload = load_json(out)
    else:
        payload = empty_layers(effective_master_map(workflow))

    payload['schemaVersion'] = 2
    payload['masterMapPath'] = effective_master_map(workflow)
    payload['updatedAt'] = now_iso()
    layers = payload.setdefault('layers', {})
    landmarks = layers.setdefault('landmarks', [])
    buildings = layers.setdefault('buildings', [])
    layers.setdefault('roads', [])
    layers.setdefault('water', [])
    layers.setdefault('bridges', [])
    layers.setdefault('districts', [])

    landmarks[:] = [item for item in landmarks if item.get('source') not in AUTO_ANCHOR_SOURCES]
    buildings[:] = [item for item in buildings if item.get('source') not in AUTO_ANCHOR_SOURCES]

    place_by_id = {p.get('id'): p for p in places if p.get('id')}

    # Anchor from worldGraph landmark nodes first.
    world_nodes = (workflow.get('worldGraph') or {}).get('nodes') or []
    for node in world_nodes:
        point = node.get('mapPoint') or {}
        place_id = node.get('placeID')
        title = node.get('title') or (place_by_id.get(place_id) or {}).get('name') or 'Unnamed Landmark'
        kind = landmark_kind(title) or 'custom'
        if point.get('x') is None or point.get('y') is None:
            continue
        feature = {
            'id': f'landmark::{place_id or title}',
            'title': title,
            'kind': kind,
            'source': 'worldGraph.node',
            'x': round(float(point['x']), 6),
            'y': round(float(point['y']), 6),
            'placeID': place_id,
        }
        upsert_feature(landmarks, feature)
        if kind in {'clinic', 'amira_home', 'gathering_space', 'marketplace'}:
            building = {
                'id': f'building::{place_id or title}',
                'title': title,
                'kind': kind,
                'source': 'worldGraph.node',
                'anchorX': round(float(point['x']), 6),
                'anchorY': round(float(point['y']), 6),
                'heightMeters': 8 if kind in {'clinic', 'amira_home'} else 10,
                'footprint': []
            }
            upsert_feature(buildings, building)

    # Also seed from high-confidence confirmed generated records.
    for record in workflow.get('generatedImageRecords') or []:
        if record.get('mapPlacementStatus') != 'confirmed':
            continue
        if record.get('isRejected'):
            continue
        if (record.get('rating') or 0) < 4:
            continue
        point = record.get('mapPoint') or {}
        if point.get('x') is None or point.get('y') is None:
            continue
        title = record.get('linkedPlaceName') or (place_by_id.get(record.get('linkedPlaceID')) or {}).get('name') or Path(record.get('activePath') or '').stem
        kind = landmark_kind(title)
        if not kind:
            continue
        place_id = record.get('linkedPlaceID')
        feature = {
            'id': f'landmark-record::{record.get("id")}',
            'title': title,
            'kind': kind,
            'source': 'generatedRecord.confirmed',
            'x': round(float(point['x']), 6),
            'y': round(float(point['y']), 6),
            'placeID': place_id,
            'recordID': record.get('id'),
            'imagePath': record.get('activePath')
        }
        upsert_feature(landmarks, feature)

    sync_draft_vectors(payload, project)
    payload['updatedAt'] = now_iso()
    save_json(out, payload)
    return out


def summarize_layers(project: Path) -> dict[str, Any]:
    out = output_path(project)
    if not out.exists():
        return {'exists': False, 'path': str(out)}
    payload = load_json(out)
    layers = payload.get('layers') or {}
    return {
        'exists': True,
        'path': str(out),
        'masterMapPath': payload.get('masterMapPath'),
        'counts': {name: len(items or []) for name, items in layers.items()},
        'landmarks': layers.get('landmarks', [])[:12]
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', default=str(DEFAULT_PROJECT))
    sub = parser.add_subparsers(dest='command', required=True)

    p_boot = sub.add_parser('bootstrap')
    p_boot.add_argument('--overwrite', action='store_true')

    sub.add_parser('status')

    args = parser.parse_args()
    project = Path(args.project)

    if args.command == 'bootstrap':
        out = bootstrap_layers(project, overwrite=args.overwrite)
        print(out)
    elif args.command == 'status':
        print(json.dumps(summarize_layers(project), indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
