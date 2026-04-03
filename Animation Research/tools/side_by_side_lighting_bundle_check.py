#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_LOCATIONS = {
    'district-clinic-exterior',
    'rooftop-sunset',
    'village-street-night',
    'clinic-interior-fluorescent',
    'family-courtyard',
}
REQUIRED_CHARACTERS = {'luke-hart', 'amira-nazari'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: side_by_side_lighting_bundle_check.py <pairs.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    pairs = payload.get('pairs', [])
    seen_locations = set()
    failing = []
    for pair in pairs:
        location_id = pair.get('locationId')
        if location_id:
            seen_locations.add(location_id)
        chars = {c.get('characterId') for c in pair.get('characters', []) if c.get('characterId')}
        if location_id is None or not pair.get('lightingProfile') or chars != REQUIRED_CHARACTERS:
            failing.append(location_id or 'unknown')
    result = {
        'pairCount': len(pairs),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen_locations),
        'valid': len(failing) == 0 and seen_locations == REQUIRED_LOCATIONS,
        'failingPairs': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
