#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def ids(items: list[dict], key: str = 'id') -> set[str]:
    return {item.get(key) for item in items if item.get(key)}


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: package_diff_report.py <old-package-json> <new-package-json>')
        return 2
    old = json.loads(Path(sys.argv[1]).read_text())
    new = json.loads(Path(sys.argv[2]).read_text())

    old_mouth = ids(old.get('mouthProfiles', []))
    new_mouth = ids(new.get('mouthProfiles', []))
    old_motion = ids(old.get('motionPrimitives', []))
    new_motion = ids(new.get('motionPrimitives', []))
    old_costumes = ids(old.get('costumePacks', []))
    new_costumes = ids(new.get('costumePacks', []))

    regressions = []
    if len(new_mouth) < len(old_mouth):
        regressions.append('mouth profile coverage dropped')
    if len(new_motion) < len(old_motion):
        regressions.append('motion primitive coverage dropped')
    if len(new_costumes) < len(old_costumes):
        regressions.append('costume pack coverage dropped')
    if old.get('qa', {}).get('status') and new.get('qa', {}).get('status'):
        order = ['draft', 'blocking-ready', 'dialogue-ready', 'performance-ready', 'production-ready']
        if order.index(new['qa']['status']) < order.index(old['qa']['status']):
            regressions.append('qa status downgraded')

    report = {
        'removedMouthProfiles': sorted(old_mouth - new_mouth),
        'addedMouthProfiles': sorted(new_mouth - old_mouth),
        'removedMotionPrimitives': sorted(old_motion - new_motion),
        'addedMotionPrimitives': sorted(new_motion - old_motion),
        'removedCostumePacks': sorted(old_costumes - new_costumes),
        'addedCostumePacks': sorted(new_costumes - old_costumes),
        'regressions': regressions,
        'hasRegression': bool(regressions),
    }
    print(json.dumps(report, indent=2))
    return 1 if regressions else 0


if __name__ == '__main__':
    raise SystemExit(main())
