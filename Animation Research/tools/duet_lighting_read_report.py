#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: duet_lighting_read_report.py <matrix.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    entries = payload.get('duetReads', [])
    result = {
        'locationCount': len(entries),
        'locations': [entry.get('locationId') for entry in entries],
        'valid': all(entry.get('sharedLight') and entry.get('Luke') and entry.get('Amira') for entry in entries),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
