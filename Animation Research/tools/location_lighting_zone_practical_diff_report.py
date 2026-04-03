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


def load_index(path: Path) -> dict[str, dict]:
    payload = json.loads(path.read_text())
    root = path.parent.parent
    result = {}
    for entry in payload.get('plans', []):
        loc = entry.get('locationId')
        rel = entry.get('path')
        if loc and rel:
            result[loc] = json.loads((root / rel).read_text())
    return result


def report(old_index: Path, new_index: Path) -> dict:
    old = load_index(old_index)
    new = load_index(new_index)
    regressions = []
    warnings = []
    removed = sorted(REQUIRED_LOCATIONS & (set(old) - set(new)))
    if removed:
        regressions.append({'severity': 'BLOCK', 'description': 'Location lighting plan coverage dropped', 'details': {'removedLocations': removed}})
    for location_id in sorted(REQUIRED_LOCATIONS & set(old) & set(new)):
        old_data = old[location_id]
        new_data = new[location_id]
        old_zones = old_data.get('zoneMetadata', {}).get('zones', [])
        new_zones = new_data.get('zoneMetadata', {}).get('zones', [])
        old_zone_assign = old_data.get('zoneChannelAssignments', {})
        new_zone_assign = new_data.get('zoneChannelAssignments', {})
        old_practicals = old_data.get('practicalMetadata', {}).get('practicals', [])
        old_practical_assign = old_data.get('practicalChannelAssignments', {})
        new_practical_assign = new_data.get('practicalChannelAssignments', {})
        for zone in old_zones:
            if zone not in new_zone_assign:
                regressions.append({'severity': 'BLOCK', 'description': f'{location_id} lost zone channel assignment', 'details': {'zone': zone}})
            elif old_zone_assign.get(zone) != new_zone_assign.get(zone):
                warnings.append({'severity': 'WARN', 'description': f'{location_id} changed zone channel assignment', 'details': {'zone': zone, 'from': old_zone_assign.get(zone), 'to': new_zone_assign.get(zone)}})
        for practical in old_practicals:
            if practical not in new_practical_assign:
                regressions.append({'severity': 'BLOCK', 'description': f'{location_id} lost practical channel assignment', 'details': {'practical': practical}})
            elif old_practical_assign.get(practical) != new_practical_assign.get(practical):
                warnings.append({'severity': 'WARN', 'description': f'{location_id} changed practical channel assignment', 'details': {'practical': practical, 'from': old_practical_assign.get(practical), 'to': new_practical_assign.get(practical)}})
        if old_data.get('zoneMetadata', {}).get('characterDepthZone') != new_data.get('zoneMetadata', {}).get('characterDepthZone'):
            warnings.append({'severity': 'WARN', 'description': f'{location_id} changed character depth zone', 'details': {'from': old_data.get('zoneMetadata', {}).get('characterDepthZone'), 'to': new_data.get('zoneMetadata', {}).get('characterDepthZone')}})
        if old_data.get('zoneMetadata', {}).get('backgroundGradeNotes') != new_data.get('zoneMetadata', {}).get('backgroundGradeNotes'):
            warnings.append({'severity': 'WARN', 'description': f'{location_id} changed background grade notes', 'details': {'from': old_data.get('zoneMetadata', {}).get('backgroundGradeNotes'), 'to': new_data.get('zoneMetadata', {}).get('backgroundGradeNotes')}})
        if old_zones != new_zones:
            warnings.append({'severity': 'WARN', 'description': f'{location_id} changed zone list', 'details': {'from': old_zones, 'to': new_zones}})
        new_practicals = new_data.get('practicalMetadata', {}).get('practicals', [])
        if old_practicals != new_practicals:
            warnings.append({'severity': 'WARN', 'description': f'{location_id} changed practical list', 'details': {'from': old_practicals, 'to': new_practicals}})
    return {
        'summary': {
            'removedLocations': removed,
            'oldLocationCount': len(old),
            'newLocationCount': len(new),
        },
        'regressions': regressions,
        'warnings': warnings,
        'hasRegression': bool(regressions),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: location_lighting_zone_practical_diff_report.py <old-index.json> <new-index.json>')
        return 2
    result = report(Path(sys.argv[1]), Path(sys.argv[2]))
    print(json.dumps(result, indent=2))
    return 1 if result['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
