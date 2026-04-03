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


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: duet_location_plan_index_check.py <index.json>')
        return 2
    index_path = Path(sys.argv[1])
    root = index_path.parent.parent
    payload = json.loads(index_path.read_text())
    plans = payload.get('plans', [])
    seen = set()
    failing = []
    for entry in plans:
        location_id = entry.get('locationId')
        rel = entry.get('path')
        if location_id:
            seen.add(location_id)
        if not location_id or not rel:
            failing.append(location_id or 'unknown')
            continue
        path = root / rel
        if not path.exists():
            failing.append(location_id)
            continue
        data = json.loads(path.read_text())
        required = ['locationId', 'lightingProfile', 'sharedLightWorld', 'lukeReadPriorities', 'amiraReadPriorities', 'zoneMetadata', 'practicalMetadata', 'zoneChannelAssignments', 'practicalChannelAssignments']
        if any(key not in data for key in required):
            failing.append(location_id)
    result = {
        'planCount': len(plans),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen),
        'valid': len(failing) == 0 and seen == REQUIRED_LOCATIONS,
        'failingPlans': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
