#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def load_location_plan(index_path: Path, location_id: str) -> dict:
    payload = json.loads(index_path.read_text())
    root = index_path.parent.parent
    for entry in payload.get('plans', []):
        if entry.get('locationId') == location_id:
            return json.loads((root / entry['path']).read_text())
    raise KeyError(location_id)


def protection_channels(focus_character: str, performance_mode: str) -> list[str]:
    channels = []
    mode = performance_mode.lower()
    if focus_character in {'luke', 'both'}:
        channels.append('ch07_luke_protect')
    if focus_character in {'amira', 'both'}:
        channels.append('ch08_amira_protect')
    if 'sung' in mode or 'dialogue' in mode:
        return channels
    return channels[:1]


def mouth_bias(camera_bias: str) -> str:
    bias = camera_bias.lower()
    if 'profile' in bias:
        return 'profile'
    if 'quarter-right' in bias:
        return 'quarterRight'
    if 'quarter-left' in bias:
        return 'quarterLeft'
    return 'front'


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: script_lighting_beat_seed.py <beat-cues.json> <location-plan-index.json>')
        return 2
    cue_path = Path(sys.argv[1])
    index_path = Path(sys.argv[2])
    payload = json.loads(cue_path.read_text())
    location_id = payload['locationId']
    plan = load_location_plan(index_path, location_id)
    beats_out = []
    for beat in payload.get('beats', []):
        active_zone = {zone: plan['zoneChannelAssignments'][zone] for zone in beat.get('zoneFocus', []) if zone in plan.get('zoneChannelAssignments', {})}
        active_practical = {practical: plan['practicalChannelAssignments'][practical] for practical in beat.get('practicalCue', []) if practical in plan.get('practicalChannelAssignments', {})}
        beats_out.append({
            'beatId': beat['beatId'],
            'description': beat['description'],
            'focusCharacter': beat['focusCharacter'],
            'activeZoneChannels': active_zone,
            'activePracticalChannels': active_practical,
            'activeProtectionChannels': protection_channels(beat['focusCharacter'], beat.get('performanceMode', '')),
            'mouthOverlayBias': mouth_bias(beat.get('cameraBias', 'front')),
            'continuityNotes': [
                'shared light world remains unchanged',
                'zone/practical emphasis only; no new channels introduced'
            ]
        })
    result = {
        'shotId': payload['shotId'],
        'locationId': location_id,
        'lightingProfile': payload['lightingProfile'],
        'sharedLightWorld': payload['sharedLightWorld'],
        'sourceLocationPlan': plan['shotId'],
        'beats': beats_out,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
