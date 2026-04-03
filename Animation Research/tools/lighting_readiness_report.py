#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_PROFILES = {'daylight_soft', 'sunset_warm', 'moonlight_blue'}


def load(path: str) -> dict:
    return json.loads(Path(path).read_text())


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: lighting_readiness_report.py <character-package.json> <location-set.json>')
        return 2
    pkg = load(sys.argv[1])
    loc = load(sys.argv[2])
    pkg_profiles = set(pkg.get('supportedLightingProfiles', []))
    loc_profiles = set(loc.get('supportedLightingProfiles', []))
    shared = sorted(pkg_profiles & loc_profiles)
    shared_required = sorted(REQUIRED_PROFILES & set(shared))
    face = bool(pkg.get('lightingDefaults', {}).get('faceProtection'))
    mouth = bool(pkg.get('lightingDefaults', {}).get('mouthVisibilityProtection'))
    result = {
        'characterId': pkg.get('characterId'),
        'locationId': loc.get('locationId'),
        'sharedProfiles': shared,
        'sharedRequiredProfiles': shared_required,
        'materialResponseCount': len(pkg.get('materialResponseIds', [])),
        'zoneCount': len(loc.get('zones', [])),
        'dialogueReady': len(shared_required) >= 3 and face and mouth,
        'performanceReady': len(shared) >= 4 and len(pkg.get('materialResponseIds', [])) >= 4 and len(loc.get('zones', [])) >= 4,
    }
    result['productionReady'] = result['performanceReady'] and 'fluorescent_clinic' in shared
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
