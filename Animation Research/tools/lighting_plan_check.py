#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_plan_check.py <plan.json>')
        return 2
    plan = json.loads(Path(sys.argv[1]).read_text())
    required = ['shotId', 'profileId', 'timeOfDay', 'characterZones', 'backgroundZones']
    missing = [key for key in required if key not in plan]
    result = {
        'valid': not missing and bool(plan.get('characterZones')),
        'missing': missing,
        'characterZoneCount': len(plan.get('characterZones', [])),
        'backgroundZoneCount': len(plan.get('backgroundZones', [])),
        'faceProtection': bool(plan.get('faceProtection')),
        'mouthVisibilityProtection': bool(plan.get('mouthVisibilityProtection')),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
