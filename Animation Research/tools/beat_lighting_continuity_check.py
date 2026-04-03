#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: beat_lighting_continuity_check.py <beat-plan.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    failing = []
    warnings = []
    shared = payload.get('sharedLightWorld')
    if not shared:
        failing.append('missing-shared-light-world')
    for beat in payload.get('beats', []):
        beat_id = beat.get('beatId', 'unknown-beat')
        notes = beat.get('continuityNotes', [])
        protections = beat.get('activeProtectionChannels', [])
        if 'shared light world remains unchanged' not in notes:
            failing.append(f'{beat_id}:missing-shared-world-note')
        if not protections:
            failing.append(f'{beat_id}:missing-protection-channels')
        for practical, channels in beat.get('activePracticalChannels', {}).items():
            if 'ch01_world_key' in channels:
                failing.append(f'{beat_id}:practical-uses-world-key:{practical}')
        bias = beat.get('mouthOverlayBias')
        if bias not in {'front', 'profile', 'quarterLeft', 'quarterRight'}:
            warnings.append(f'{beat_id}:unusual-mouth-bias:{bias}')
    result = {
        'valid': not failing,
        'sharedLightWorld': shared,
        'failing': failing,
        'warnings': warnings,
        'beatCount': len(payload.get('beats', [])),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
