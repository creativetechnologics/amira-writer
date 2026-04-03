#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: mouth_preset_report.py <preset-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    summary = {}
    for character, angle_map in payload.items():
        summary[character] = {
            'angleCount': len(angle_map),
            'modeCount': sum(len(modes) for modes in angle_map.values())
        }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
