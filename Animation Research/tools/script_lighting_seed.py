#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

PROFILE_BY_TIME = {
    'dawn': 'daylight_soft',
    'morning': 'daylight_soft',
    'noon': 'daylight_hard',
    'sunset': 'sunset_warm',
    'dusk': 'sunset_warm',
    'night': 'moonlight_blue',
}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: script_lighting_seed.py <script-cues.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    cues = payload.get('scriptCues', {})
    time_of_day = cues.get('timeOfDay', 'morning')
    camera = cues.get('camera', '')
    performance = cues.get('performance', '')
    weather = cues.get('weather', '').lower()
    practicals = ' '.join(cues.get('practicals', [])).lower()
    profile = PROFILE_BY_TIME.get(time_of_day, 'daylight_soft')
    blob = json.dumps(cues).lower()

    if 'fluorescent' in blob:
        profile = 'fluorescent_clinic'
    if 'fire' in blob or 'candle' in blob:
        profile = 'firelight_flicker'
    if 'dust' in weather or 'sand' in weather:
        profile = 'dust_storm_flat' if time_of_day in {'morning', 'noon', 'day'} else profile

    modifiers: list[str] = []
    if 'dust' in weather or 'sand' in weather:
        modifiers.append('haze-up')
        modifiers.append('contrast-down')
    if 'smoke' in weather or 'fog' in weather:
        modifiers.append('depth-haze-up')
    if 'fire' in practicals or 'candle' in practicals:
        modifiers.append('flicker-practical')
    if 'fluorescent' in practicals:
        modifiers.append('cool-fill')
    if 'profile' in camera:
        modifiers.append('rim-preferred')

    face_protect = 'close-up' in camera or 'medium close-up' in camera
    mouth_protect = 'sung' in performance.lower() or 'dialogue' in performance.lower()
    result = {
        'shotId': payload.get('shotId'),
        'profileId': profile,
        'timeOfDay': time_of_day,
        'faceProtection': face_protect,
        'mouthVisibilityProtection': mouth_protect,
        'cameraBias': 'profile' if 'profile' in camera else 'frontal',
        'weatherModifiers': sorted(set(modifiers)),
        'practicalSummary': sorted(set(cues.get('practicals', []))),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
