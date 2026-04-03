#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: script_lighting_beat_plan_check.py <beat-plan.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    failing = []
    if not payload.get('shotId') or not payload.get('locationId') or not payload.get('lightingProfile'):
        failing.append('missing-top-level-fields')
    if not payload.get('sharedLightWorld'):
        failing.append('missing-shared-light-world')
    beats = payload.get('beats', [])
    if not beats:
        failing.append('missing-beats')
    for beat in beats:
        if not beat.get('beatId') or not beat.get('activeProtectionChannels') or not beat.get('mouthOverlayBias'):
            failing.append(beat.get('beatId', 'unknown-beat'))
        if 'shared light world remains unchanged' not in beat.get('continuityNotes', []):
            failing.append(f"{beat.get('beatId','unknown-beat')}:missing-continuity-note")
    result = {
        'valid': not failing,
        'beatCount': len(beats),
        'failing': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
