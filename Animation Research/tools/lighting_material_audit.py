#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_material_audit.py <catalog.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    responses = payload.get('responses', [])
    ids = [r.get('id') for r in responses if r.get('id')]
    result = {
        'catalogId': payload.get('catalogId'),
        'responseCount': len(responses),
        'skinProtectedCount': sum(1 for r in responses if r.get('skinToneProtection') is True),
        'lineProtectedCount': sum(1 for r in responses if float(r.get('lineProtection', 0)) >= 0.8),
        'ids': ids,
        'valid': len(responses) > 0 and all('materialFamily' in r for r in responses),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
