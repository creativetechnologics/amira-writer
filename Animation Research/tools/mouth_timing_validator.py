#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ALLOWED = {'rest','mbp','ee_tight','eh_mid','aa_wide','oh_round','oo_pucker','fv','l_tongue','smile','belt','strain'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: mouth_timing_validator.py <lyric-mouth-plan-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    errors: list[str] = []
    events = payload.get('events', [])
    last_frame = -1
    for idx, event in enumerate(events, start=1):
        frame = event.get('frame')
        shape = event.get('shape')
        if not isinstance(frame, int) or frame < 0:
            errors.append(f'events[{idx}] invalid frame')
        if isinstance(frame, int) and frame <= last_frame:
            errors.append(f'events[{idx}] frame is not strictly increasing')
        if shape not in ALLOWED:
            errors.append(f'events[{idx}] invalid shape {shape}')
        if isinstance(frame, int):
            last_frame = frame
    if errors:
        print('INVALID')
        for item in errors:
            print(f'- {item}')
        return 1
    print('VALID')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
