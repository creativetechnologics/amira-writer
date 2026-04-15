from __future__ import annotations
import json, shutil, re
from pathlib import Path
from datetime import datetime
from uuid import uuid4

PROJECT_ROOT = Path('/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera')
ANIMATE_DIR = PROJECT_ROOT / 'Animate'
PLACES_PATH = ANIMATE_DIR / 'places.json'
WORKFLOW_PATH = ANIMATE_DIR / 'places-workflow.json'
DESKTOP = Path('/Volumes/Storage VIII/Users/gary/Desktop/Amira Background Generations')
CHOSEN = ANIMATE_DIR / 'backgrounds' / 'chosen-references'


def normalized_key(value: str) -> str:
    lowered = value.lower().replace('&', ' and ')
    lowered = re.sub(r'[^a-z0-9]+', ' ', lowered)
    return ' '.join(lowered.split())


def file_stem(value: str) -> str:
    return normalized_key(value).replace(' ', '-')


def project_relative(path: Path) -> str:
    path = path.resolve()
    try:
        return path.relative_to(PROJECT_ROOT).as_posix()
    except ValueError:
        p = path.as_posix()
        marker = '/Animate/'
        if marker in p:
            return 'Animate/' + p.split(marker, 1)[1]
        return p


def unique_dest(directory: Path, filename: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    dest = directory / filename
    if not dest.exists():
        return dest
    stem = dest.stem
    ext = dest.suffix
    counter = 2
    while True:
        candidate = directory / f"{stem}-{counter}{ext}"
        if not candidate.exists():
            return candidate
        counter += 1


def copy_into_place(place_name: str, source: Path, workflow: str='photoreal') -> str:
    category = 'photoreal' if workflow == 'photoreal' else 'animated'
    dest_dir = ANIMATE_DIR / 'backgrounds' / 'places' / file_stem(place_name) / category
    dest = unique_dest(dest_dir, source.name)
    shutil.copy2(source, dest)
    return project_relative(dest)


def make_ref(title: str, path: str, category: str, notes: str = '') -> dict:
    return {
        'id': str(uuid4()),
        'title': title,
        'imagePath': path,
        'category': category,
        'notes': notes,
    }


def ensure_ref_list(existing: list[dict], refs: list[dict]) -> list[dict]:
    by_path = {item.get('imagePath'): item for item in existing if item.get('imagePath')}
    for ref in refs:
        by_path.setdefault(ref['imagePath'], ref)
    return list(by_path.values())

MASTER_MAP = (CHOSEN / 'map' / '01-master_valley_topdown_map_4k_v5.png').resolve()
BRIDGE_REFS = [
    (CHOSEN / 'bridge' / '01-bridge-design-01-downstream-profile.png').resolve(),
    (CHOSEN / 'bridge' / '03-bridge-design-03-ridge-approach.png').resolve(),
    (CHOSEN / 'bridge' / '08-bridge-design-08-deck-width-study.png').resolve(),
    (CHOSEN / 'bridge' / '10-bridge-design-10-bridge-and-river-geometry.png').resolve(),
]

TOWN_STUDIES = DESKTOP / 'Amira Town Studies 2026-04-12 1602' / 'outputs'
TOWN_BATCH = DESKTOP / 'Amira Town Liveliness Batch 2026-04-12 1641' / 'results'

ASSETS = {
    'ridge01': TOWN_STUDIES / '01-town-01-ridge-establishing-day.png',
    'west02': TOWN_STUDIES / '02-town-02-town-from-west-approach.png',
    'river03': TOWN_STUDIES / '03-town-03-lower-town-riverside.png',
    'market04': TOWN_STUDIES / '04-town-04-marketplace-main-lane.png',
    'market05': TOWN_STUDIES / '05-town-05-marketplace-awning-corridor.png',
    'market06': TOWN_STUDIES / '06-town-06-market-square-open.png',
    'street07': TOWN_STUDIES / '07-town-07-main-street-uphill.png',
    'street08': TOWN_STUDIES / '08-town-08-main-street-color-mix.png',
    'street09': TOWN_STUDIES / '09-town-09-narrow-street-lower-district.png',
    'street10': TOWN_STUDIES / '10-town-10-narrow-street-upper-district.png',
    'lane11': TOWN_STUDIES / '11-town-11-upper-residential-lane.png',
    'gathering12': TOWN_STUDIES / '12-town-12-gathering-space-exterior.png',
    'clinic13': TOWN_STUDIES / '13-town-13-clinic-exterior-front.png',
    'clinic14': TOWN_STUDIES / '14-town-14-clinic-exterior-side-street.png',
    'clinic15': TOWN_STUDIES / '15-town-15-clinic-small-courtyard.png',
    'bridge16': TOWN_STUDIES / '16-town-16-bridge-into-town.png',
    'bridge17': TOWN_STUDIES / '17-town-17-from-town-toward-bridge.png',
    'river18': TOWN_STUDIES / '18-town-18-river-path-and-town.png',
    'edge19': TOWN_STUDIES / '19-town-19-neighborhood-edge-terraces.png',
    'dusk20': TOWN_STUDIES / '20-town-20-dusk-main-street-lights.png',
    'wide21': TOWN_BATCH / 'town-wide-21-south-ridge-full-spread-morning.jpg',
    'wide23': TOWN_BATCH / 'town-wide-23-west-approach-long-view.jpg',
    'wide30': TOWN_BATCH / 'town-wide-30-riverside-bend-full-town.jpg',
    'wide31': TOWN_BATCH / 'town-wide-31-upper-slope-looking-down.jpg',
    'wide35': TOWN_BATCH / 'town-wide-35-blue-hour-across-river.jpg',
    'wide39': TOWN_BATCH / 'town-wide-39-bridge-secondary-town-primary.jpg',
    'wide40': TOWN_BATCH / 'town-wide-40-full-town-glacier-context.jpg',
}

PLACE_PLAN = {
    'Mountain Valley / The Ridge - Dawn (day 1)': {
        'photos': ['wide21', 'ridge01', 'wide40'],
        'approved': 'wide21',
        'note': 'Use the south-ridge establishing family. Respect the master map: town only on the north bank, empty south ridge, and liveliness visible across the full settlement footprint.',
    },
    'The Ridge - Dawn (day 1)': {
        'photos': ['ridge01', 'wide21'],
        'approved': 'ridge01',
        'note': 'Wide ridge-side dawn geography. Town remains inhabited across the whole visible footprint; do not let the outskirts collapse into ruins.',
    },
    'The Ridge / Convoy Unload - Dawn (day 1)': {
        'photos': ['wide23', 'west02'],
        'approved': 'wide23',
        'note': 'West approach / base separation logic. The town dominates the north bank while any base presence stays far smaller and farther southwest.',
    },
    'The Marketplace / Village Streets - Dinner Hour (day 1)': {
        'photos': ['dusk20', 'market04', 'market05', 'market06'],
        'approved': 'dusk20',
        'note': 'Lower-town market core at dinner hour. Keep it lively, repaired, colorful, and modest; no fantasy plaza or dead ruin-city feel.',
    },
    'Village Street / The Village Clinic - Morning (day 3)': {
        'photos': ['clinic14', 'clinic13', 'clinic15'],
        'approved': 'clinic14',
        'note': 'Clinic-adjacent street on the north bank. Preserve lived-in density and keep the far side of the river empty of buildings.',
    },
    'Village Street - Morning (day 3)': {
        'photos': ['street08', 'street07', 'street09', 'street10'],
        'approved': 'street08',
        'note': 'Active village street with mixed repairs, textiles, awnings, and daily-life detail. Avoid monumental ruin vibes.',
    },
    'Village Courtyard / Lane - Morning (day 3)': {
        'photos': ['lane11', 'street10'],
        'approved': 'lane11',
        'note': 'Modest north-bank lane/courtyard feeling within a real inhabited town.',
    },
    'Village Edge - Late Day (day 3)': {
        'photos': ['edge19', 'wide31'],
        'approved': 'edge19',
        'note': 'Upper residential edge and terraces. The edge of town should still feel inhabited, not abandoned rubble.',
    },
    'Village to Bridge - Pre-dawn (day 3)': {
        'photos': ['bridge17', 'bridge16', 'wide39'],
        'approved': 'bridge17',
        'note': 'Bridge-and-lower-town approach family. Canonical bridge only; settlement stays on the north bank.',
        'bridge_refs': True,
    },
    'The Bridge - Dawn (day 3)': {
        'photos': ['bridge16', 'bridge17'],
        'approved': 'bridge16',
        'note': 'Canonical single-lane stone bridge only. Do not invent extra spans or extra settlement on the south bank.',
        'bridge_refs': True,
    },
    'The Bridge / The Ridge - Dawn (day 3)': {
        'photos': ['wide39'],
        'approved': 'wide39',
        'note': 'Bridge plus ridge geography. Keep the bridge secondary to the town mass and respect one-sided town geography.',
        'bridge_refs': True,
    },
    'The Bridge / River Edge - Later (day 3)': {
        'photos': ['river18'],
        'approved': 'river18',
        'note': 'River-edge perspective with the canonical bridge logic and no development on the south bank.',
        'bridge_refs': True,
    },
    'The Riverside - Day 3': {
        'photos': ['river18', 'wide30'],
        'approved': 'river18',
        'note': 'North-bank riverside perspective. The opposite bank should remain ridge/cemetery terrain only.',
    },
    'The Gathering Space - Early Afternoon (day 1)': {
        'refs_only': ['gathering12'],
        'note': 'Gathering-space architecture should stay modest and inhabited rather than grand or formal.',
    },
    'The Village Clinic - Late Afternoon (day 1)': {
        'refs_only': ['clinic13', 'clinic14', 'clinic15'],
        'note': 'Clinic architecture and street-facing exterior references only; interiors should still feel used and alive.',
    },
    'The Village Clinic - Early Evening (day 1)': {
        'refs_only': ['clinic13', 'clinic14', 'clinic15'],
        'note': 'Clinic architecture and street-facing exterior references only; interiors should still feel used and alive.',
    },
    'The Village Clinic - Night (day 2)': {
        'refs_only': ['clinic13', 'clinic14', 'clinic15'],
        'note': 'Clinic architecture and access-lane references; keep all interiors grounded and inhabited.',
    },
    'Village Clinic Back Room - Pre-dawn (day 3)': {
        'refs_only': ['clinic13', 'clinic14'],
        'note': 'Use the established clinic exterior and lane architecture as continuity support for interiors.',
    },
}

# Backup existing files
stamp = datetime.now().strftime('%Y%m%dT%H%M%S')
shutil.copy2(PLACES_PATH, PLACES_PATH.with_suffix(f'.json.bak-{stamp}'))
if WORKFLOW_PATH.exists():
    shutil.copy2(WORKFLOW_PATH, WORKFLOW_PATH.with_suffix(f'.json.bak-{stamp}'))

places = json.loads(PLACES_PATH.read_text())
workflow = json.loads(WORKFLOW_PATH.read_text()) if WORKFLOW_PATH.exists() else {
    'masterMapImagePath': None,
    'landmarkReferences': [],
    'photorealConfig': {
        'model': 'gemini-3.1-flash-image-preview',
        'aspectRatio': '16:9',
        'imageSize': '1K',
        'lensDescription': 'Shot on a full-frame camera with grounded cinematic photography, strong depth of field control, and lensing appropriate to the composition.',
        'promptPrefix': 'Use the approved master map and landmark references whenever they are relevant. Generate a real photographic still, not a painted matte backdrop.',
        'promptSuffix': 'Preserve world continuity, but re-photograph the location rather than copying a prior frame 1:1.'
    },
    'animatedConfig': {
        'model': 'gemini-3.1-flash-image-preview',
        'aspectRatio': '16:9',
        'imageSize': '1K',
        'lensDescription': 'Cinematic animated staging with full-frame lens logic, believable depth separation, and the same world geography as the photoreal continuity plates.',
        'promptPrefix': 'Use the approved photoreal continuity plate plus the animated references to restage the same location in the animated Amira look.',
        'promptSuffix': 'Preserve scale, bridge placement, and river-bank logic; do not copy the photoreal frame 1:1.'
    }
}
workflow['masterMapImagePath'] = project_relative(MASTER_MAP)
existing_landmarks = workflow.get('landmarkReferences', [])
landmark_paths = {item.get('imagePath') for item in existing_landmarks}
for ref in BRIDGE_REFS:
    rel = project_relative(ref)
    if rel not in landmark_paths:
        existing_landmarks.append(make_ref(ref.stem.replace('-', ' ').title(), rel, 'bridge', 'Chosen bridge canon reference.'))
workflow['landmarkReferences'] = existing_landmarks

places_by_name = {place['name']: place for place in places}

for place_name, plan in PLACE_PLAN.items():
    place = places_by_name.get(place_name)
    if not place:
        print(f'WARN missing place: {place_name}')
        continue

    # Ensure fields exist
    place.setdefault('referenceImages', [])
    place.setdefault('workflowPromptNotes', '')
    place.setdefault('animatedImagePaths', [])
    place.setdefault('animatedApprovedImagePath', None)
    place.setdefault('imagePaths', [])

    if 'note' in plan:
        place['workflowPromptNotes'] = plan['note']

    bridge_refs = []
    if plan.get('bridge_refs'):
        bridge_refs = [make_ref(ref.stem.replace('-', ' ').title(), project_relative(ref), 'bridge', 'Chosen bridge canon reference.') for ref in BRIDGE_REFS]

    extra_refs = []
    for key in plan.get('refs_only', []):
        source = ASSETS[key]
        copied = copy_into_place(place_name, source, workflow='photoreal')
        extra_refs.append(make_ref(source.stem.replace('-', ' ').replace('_', ' '), copied, 'architecture', 'Useful generated exterior continuity reference from April 12.'))

    if 'photos' in plan:
        copied_paths = []
        for key in plan['photos']:
            source = ASSETS[key]
            copied_paths.append(copy_into_place(place_name, source, workflow='photoreal'))
        # de-dupe while preserving order
        merged = []
        seen = set(place.get('imagePaths', []))
        for path in place.get('imagePaths', []) + copied_paths:
            if path not in seen:
                seen.add(path)
                merged.append(path)
        # if existing imagePaths were empty, keep copied_paths
        if not place.get('imagePaths'):
            merged = []
            for path in copied_paths:
                if path not in merged:
                    merged.append(path)
        place['imagePaths'] = merged
        approved_source = ASSETS[plan['approved']]
        # find copied path by filename suffix match on most recent copies
        approved_candidates = [p for p in copied_paths if Path(p).name == approved_source.name]
        approved = approved_candidates[0] if approved_candidates else copied_paths[0]
        place['approvedImagePath'] = approved
        place['filename'] = Path(approved).name

    place['referenceImages'] = ensure_ref_list(place['referenceImages'], bridge_refs + extra_refs)

PLACES_PATH.write_text(json.dumps(places, indent=2, sort_keys=True))
WORKFLOW_PATH.write_text(json.dumps(workflow, indent=2, sort_keys=True))
print('Updated', PLACES_PATH)
print('Updated', WORKFLOW_PATH)
print('Master map:', workflow['masterMapImagePath'])
print('Global landmarks:', len(workflow['landmarkReferences']))
for name in PLACE_PLAN:
    if name in places_by_name:
        p = places_by_name[name]
        print(f"{name}: {len(p.get('imagePaths', []))} photo, {len(p.get('referenceImages', []))} refs, approved={p.get('approvedImagePath')}")
