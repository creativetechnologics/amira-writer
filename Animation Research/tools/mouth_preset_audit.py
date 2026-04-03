#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_KEYS = {'opennessBias', 'releaseSoftness'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: mouth_preset_audit.py <preset-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    problems = []
    for character, angle_map in payload.items():
        for angle, mode_map in angle_map.items():
            for mode, emotion_map in mode_map.items():
                for emotion, preset in emotion_map.items():
                    missing = sorted(REQUIRED_KEYS - preset.keys())
                    if missing:
                        problems.append(f'{character}/{angle}/{mode}/{emotion} missing {missing}')
    print(json.dumps({'valid': not problems, 'problems': problems}, indent=2))
    return 0 if not problems else 1


if __name__ == '__main__':
    raise SystemExit(main())
