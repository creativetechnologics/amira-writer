#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_LOCATIONS = {
    'district-clinic-exterior',
    'rooftop-sunset',
    'village-street-night',
    'clinic-interior-fluorescent',
    'family-courtyard',
}
REQUIRED_KEYS = {
    'packetId',
    'locationId',
    'lightingPlanFixture',
    'duetLightingPacketFixture',
    'routingMode',
    'motionBeats',
    'mouthOverlay',
    'channelContinuityRules',
}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: duet_motion_lighting_packet_check.py <packets.json>')
        return 2
    path = Path(sys.argv[1])
    payload = json.loads(path.read_text())
    packets = payload.get('packets', [])
    seen = set()
    failures: list[str] = []

    for packet in packets:
        missing = REQUIRED_KEYS - packet.keys()
        location_id = packet.get('locationId', 'unknown')
        if location_id:
            seen.add(location_id)
        if missing:
            failures.append(f'{location_id}:missing:{sorted(missing)}')
            continue
        beats = packet.get('motionBeats', [])
        if len(beats) < 2:
            failures.append(f'{location_id}:too-few-beats')
        for beat in beats:
            if not beat.get('beatId') or not beat.get('activeChannels') or not beat.get('mouthAngles'):
                failures.append(f'{location_id}:invalid-beat')
                break

    result = {
        'valid': seen == REQUIRED_LOCATIONS and not failures,
        'packetCount': len(packets),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen),
        'failures': failures,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
