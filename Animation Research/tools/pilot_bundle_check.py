#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: pilot_bundle_check.py <pilot-shot-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    required = payload.get('requiredAssets', {})
    ok = all(required.get(key) for key in ['sheets', 'bodyPrimitives', 'mouthShapes'])
    print('VALID' if ok else 'INVALID')
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
