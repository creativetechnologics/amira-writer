#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = {'daylight_soft', 'sunset_warm', 'moonlight_blue', 'fluorescent_clinic'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_profile_library_check.py <library.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    profiles = payload.get('profiles', [])
    ids = {p.get('id') for p in profiles if p.get('id')}
    missing = sorted(REQUIRED - ids)
    result = {
        'libraryId': payload.get('libraryId'),
        'profileCount': len(profiles),
        'missingRequired': missing,
        'valid': len(missing) == 0,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
