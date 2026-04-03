#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: hero_lighting_read_report.py <comparisons.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    comparisons = payload.get('comparisons', [])
    result = {
        'locationCount': len(comparisons),
        'locations': [entry.get('locationId') for entry in comparisons],
        'valid': all(entry.get('Luke Hart') and entry.get('Amira Nazari') for entry in comparisons),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
