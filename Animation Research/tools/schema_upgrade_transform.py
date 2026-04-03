#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def transform(payload: dict) -> dict:
    upgraded = dict(payload)
    upgraded['schemaVersion'] = max(2, int(payload.get('schemaVersion', 1)))
    upgraded.setdefault('mouthProfiles', [])
    upgraded.setdefault('qa', {'status': 'draft'})
    if 'defaults' not in upgraded:
        costume_packs = upgraded.get('costumePacks', [])
        upgraded['defaults'] = {'defaultCostumePackID': costume_packs[0]['id'] if costume_packs else None}
    return upgraded


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: schema_upgrade_transform.py <manifest-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    print(json.dumps(transform(payload), indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
