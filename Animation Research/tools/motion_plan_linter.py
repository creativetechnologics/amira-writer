#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ALLOWED_ROUTING = {'internal', 'hybrid', 'aiVideoFallback', 'aiVideoFirst', 'manual'}


def lint(payload: dict) -> list[str]:
    errors: list[str] = []
    if payload.get('shotRouting', {}).get('mode') not in ALLOWED_ROUTING:
        errors.append('Invalid or missing shotRouting.mode')

    states = {entry.get('characterId') for entry in payload.get('characterStates', []) if entry.get('characterId')}
    if not states:
        errors.append('No characterStates provided')

    for idx, primitive in enumerate(payload.get('motionPrimitives', []), start=1):
        cid = primitive.get('characterId')
        if cid and cid not in states:
            errors.append(f'motionPrimitives[{idx}] references unknown characterId {cid}')
        if primitive.get('durationFrames', 0) <= 0:
            errors.append(f'motionPrimitives[{idx}] has non-positive durationFrames')

    for idx, mouth in enumerate(payload.get('mouthPlans', []), start=1):
        cid = mouth.get('characterId')
        if cid not in states:
            errors.append(f'mouthPlans[{idx}] references unknown characterId {cid}')
        if mouth.get('mode') not in {'speech', 'singing'}:
            errors.append(f'mouthPlans[{idx}] has invalid mode')

    for idx, overlay in enumerate(payload.get('overlays', []), start=1):
        start = overlay.get('startFrame')
        end = overlay.get('endFrame')
        if start is not None and end is not None and end < start:
            errors.append(f'overlays[{idx}] ends before it starts')

    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: motion_plan_linter.py <motion-plan-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    errors = lint(payload)
    if errors:
        print('INVALID')
        for item in errors:
            print(f'- {item}')
        return 1
    print('VALID')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
