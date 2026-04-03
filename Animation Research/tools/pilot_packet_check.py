#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = {'packetId', 'characterId', 'shotId', 'costumePackId', 'routingMode', 'readinessStatus', 'requiredFiles'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: pilot_packet_check.py <packet-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    missing = sorted(REQUIRED - payload.keys())
    ok = not missing and bool(payload.get('requiredFiles'))
    print(json.dumps({'valid': ok, 'missing': missing}, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
