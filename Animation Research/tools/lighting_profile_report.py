#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_profile_report.py <profile.json>')
        return 2
    profile = json.loads(Path(sys.argv[1]).read_text())
    result = {
        'id': profile.get('id'),
        'category': profile.get('category'),
        'hasRimLight': bool(profile.get('rimLight', {}).get('enabled')),
        'hasAtmosphere': 'atmosphere' in profile,
        'practicalSourceCount': len(profile.get('practicalSources', [])),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
