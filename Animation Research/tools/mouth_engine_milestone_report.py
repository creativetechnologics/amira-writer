#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: mouth_engine_milestone_report.py <milestone-map.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    milestones = payload.get('milestones', [])
    ids = {item.get('id') for item in milestones if item.get('id')}
    invalid = []
    ordered = []

    for item in milestones:
        milestone_id = item.get('id')
        if not milestone_id:
            invalid.append('missing-id')
            continue
        missing_deps = [dep for dep in item.get('dependsOn', []) if dep not in ids]
        if missing_deps:
            invalid.append(f'{milestone_id}:missing-dependencies:{",".join(missing_deps)}')
        if not item.get('requiredDocs') or not item.get('requiredFixtures') or not item.get('requiredOutputs'):
            invalid.append(f'{milestone_id}:missing-requirements')
        ordered.append(milestone_id)

    result = {
        'milestoneCount': len(milestones),
        'orderedMilestones': ordered,
        'valid': not invalid,
        'invalidEntries': invalid,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
