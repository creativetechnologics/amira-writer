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
        print('Usage: location_lighting_zone_practical_check.py <index.json>')
        return 2
    index_path = Path(sys.argv[1])
    root = index_path.parent.parent
    payload = json.loads(index_path.read_text())
    failing = []
    seen = set()
    for entry in payload.get('plans', []):
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
        zones = data.get('zoneMetadata', {}).get('zones', [])
        zone_assign = data.get('zoneChannelAssignments')
        practicals = data.get('practicalMetadata', {}).get('practicals', [])
        practical_assign = data.get('practicalChannelAssignments')
        if not isinstance(zone_assign, dict):
            failing.append(f'{location_id}:missing-zone-assignments')
            continue
        for zone in zones:
            if zone not in zone_assign:
                failing.append(f'{location_id}:missing-zone:{zone}')
        if practicals and not isinstance(practical_assign, dict):
            failing.append(f'{location_id}:missing-practical-assignments')
            continue
        for practical in practicals:
            if practical not in (practical_assign or {}):
                failing.append(f'{location_id}:missing-practical:{practical}')
    result = {
        'valid': seen == REQUIRED_LOCATIONS and not failing,
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen),
        'failingPlans': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
