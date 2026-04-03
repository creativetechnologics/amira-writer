#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def beat_map(payload: dict) -> dict[str, dict]:
    return {beat.get('beatId'): beat for beat in payload.get('beats', []) if beat.get('beatId')}


def report(old: dict, new: dict) -> dict:
    regressions = []
    warnings = []
    if old.get('sharedLightWorld') != new.get('sharedLightWorld'):
        regressions.append({
            'severity': 'BLOCK',
            'description': 'Shared light world changed',
            'details': {'from': old.get('sharedLightWorld'), 'to': new.get('sharedLightWorld')},
        })
    old_beats = beat_map(old)
    new_beats = beat_map(new)
    removed_beats = sorted(set(old_beats) - set(new_beats))
    if removed_beats:
        regressions.append({
            'severity': 'BLOCK',
            'description': 'Beat coverage dropped',
            'details': {'removedBeats': removed_beats},
        })
    for beat_id in sorted(set(old_beats) & set(new_beats)):
        old_beat = old_beats[beat_id]
        new_beat = new_beats[beat_id]
        if old_beat.get('activeProtectionChannels') and not new_beat.get('activeProtectionChannels'):
            regressions.append({
                'severity': 'BLOCK',
                'description': f'{beat_id} lost protection channels',
                'details': {'from': old_beat.get('activeProtectionChannels'), 'to': new_beat.get('activeProtectionChannels')},
            })
        if 'shared light world remains unchanged' in old_beat.get('continuityNotes', []) and 'shared light world remains unchanged' not in new_beat.get('continuityNotes', []):
            regressions.append({
                'severity': 'BLOCK',
                'description': f'{beat_id} lost shared-world continuity note',
                'details': {},
            })
        for practical, channels in new_beat.get('activePracticalChannels', {}).items():
            if 'ch01_world_key' in channels:
                regressions.append({
                    'severity': 'BLOCK',
                    'description': f'{beat_id} practical channel hijacks world key',
                    'details': {'practical': practical, 'channels': channels},
                })
        if old_beat.get('mouthOverlayBias') != new_beat.get('mouthOverlayBias'):
            warnings.append({
                'severity': 'WARN',
                'description': f'{beat_id} changed mouth overlay bias',
                'details': {'from': old_beat.get('mouthOverlayBias'), 'to': new_beat.get('mouthOverlayBias')},
            })
        if old_beat.get('activePracticalChannels') != new_beat.get('activePracticalChannels'):
            warnings.append({
                'severity': 'WARN',
                'description': f'{beat_id} changed practical emphasis',
                'details': {'from': old_beat.get('activePracticalChannels'), 'to': new_beat.get('activePracticalChannels')},
            })
    return {
        'summary': {
            'oldBeatCount': len(old_beats),
            'newBeatCount': len(new_beats),
            'removedBeats': removed_beats,
        },
        'regressions': regressions,
        'warnings': warnings,
        'hasRegression': bool(regressions),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: beat_lighting_diff_report.py <old-beat-plan.json> <new-beat-plan.json>')
        return 2
    old = json.loads(Path(sys.argv[1]).read_text())
    new = json.loads(Path(sys.argv[2]).read_text())
    payload = report(old, new)
    print(json.dumps(payload, indent=2))
    return 1 if payload['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
