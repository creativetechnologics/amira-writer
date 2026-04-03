#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = {'packetId', 'targets', 'fixtures'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: handoff_packet_check.py <handoff-packet-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    missing = sorted(REQUIRED - payload.keys())
    ok = not missing and bool(payload.get('targets')) and bool(payload.get('fixtures'))
    print(json.dumps({'valid': ok, 'missing': missing}, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
