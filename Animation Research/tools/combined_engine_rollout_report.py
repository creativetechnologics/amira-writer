#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_SUBSYSTEMS = {'body', 'mouth', 'lighting'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: combined_engine_rollout_report.py <rollout-matrix.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    bands = payload.get('bands', [])
    ids = {item.get('id') for item in bands if item.get('id')}
    invalid: list[str] = []
    ordered: list[str] = []

    for band in bands:
        band_id = band.get('id')
        if not band_id:
            invalid.append('missing-band-id')
            continue
        ordered.append(band_id)
        missing_deps = [dep for dep in band.get('dependsOn', []) if dep not in ids]
        if missing_deps:
            invalid.append(f'{band_id}:missing-dependencies:{",".join(missing_deps)}')
        missing_subsystems = sorted(REQUIRED_SUBSYSTEMS - set(k for k in band.keys() if k in REQUIRED_SUBSYSTEMS))
        if missing_subsystems:
            invalid.append(f'{band_id}:missing-subsystems:{",".join(missing_subsystems)}')
        for subsystem in REQUIRED_SUBSYSTEMS:
            entry = band.get(subsystem, {})
            if not entry.get('requiredDocs') or not entry.get('requiredFixtures') or not entry.get('requiredOutputs'):
                invalid.append(f'{band_id}:{subsystem}:missing-requirements')

    result = {
        'bandCount': len(bands),
        'orderedBands': ordered,
        'valid': not invalid,
        'invalidEntries': invalid,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
