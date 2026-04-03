#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: package_tier_audit.py <tier> <package-json>')
        return 2
    tier = sys.argv[1]
    payload = json.loads(Path(sys.argv[2]).read_text())
    mouth_profiles = len(payload.get('mouthProfiles', []))
    motion_primitives = len(payload.get('motionPrimitives', []))
    costume_packs = len(payload.get('costumePacks', []))
    issues: list[str] = []
    if tier == 'hero':
        if mouth_profiles < 3:
            issues.append('hero package needs at least 3 mouth profiles')
        if motion_primitives < 10:
            issues.append('hero package needs at least 10 motion primitives')
    elif tier == 'supporting':
        if mouth_profiles < 1:
            issues.append('supporting package needs at least 1 mouth profile')
        if motion_primitives < 5:
            issues.append('supporting package needs at least 5 motion primitives')
    elif tier == 'background':
        if motion_primitives < 1:
            issues.append('background package needs at least 1 motion primitive')
    result = {'tier': tier, 'costumePackCount': costume_packs, 'issues': issues, 'valid': not issues}
    print(json.dumps(result, indent=2))
    return 0 if not issues else 1


if __name__ == '__main__':
    raise SystemExit(main())
