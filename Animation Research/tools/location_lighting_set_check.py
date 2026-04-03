#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: location_lighting_set_check.py <locations.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    locations = payload.get('locations', [])
    failing = []
    for loc in locations:
        if not loc.get('locationId') or not loc.get('supportedLightingProfiles') or not loc.get('zones'):
            failing.append(loc.get('locationId', 'unknown'))
    result = {
        'locationCount': len(locations),
        'valid': len(failing) == 0,
        'failingLocations': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
