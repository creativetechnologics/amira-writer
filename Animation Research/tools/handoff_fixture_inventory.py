#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: handoff_fixture_inventory.py <fixture-dir>')
        return 2
    base = Path(sys.argv[1])
    payload = {
        'files': sorted(str(path.relative_to(base)) for path in base.rglob('*') if path.is_file()),
        'count': sum(1 for path in base.rglob('*') if path.is_file())
    }
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
