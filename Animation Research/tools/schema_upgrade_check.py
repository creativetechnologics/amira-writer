#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: schema_upgrade_check.py <manifest-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    missing = []
    if 'schemaVersion' not in payload:
        missing.append('schemaVersion')
    if 'mouthProfiles' not in payload:
        missing.append('mouthProfiles')
    if 'qa' not in payload:
        missing.append('qa')
    print(json.dumps({'upgradeSuggested': bool(missing), 'missingFields': missing}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
