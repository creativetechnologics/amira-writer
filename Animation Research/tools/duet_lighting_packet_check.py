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


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: duet_lighting_packet_check.py <packets.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    packets = payload.get('packets', [])
    locations = set()
    failing = []
    for packet in packets:
        location = packet.get('locationId')
        if location:
            locations.add(location)
        chars = packet.get('characters', [])
        ids = {c.get('characterId') for c in chars if c.get('characterId')}
        if not packet.get('lightingProfile') or ids != {'luke-hart', 'amira-nazari'} or not packet.get('sharedLightWorldNotes'):
            failing.append(packet.get('packetId', 'unknown'))
    result = {
        'packetCount': len(packets),
        'missingLocations': sorted(REQUIRED_LOCATIONS - locations),
        'valid': len(failing) == 0 and locations == REQUIRED_LOCATIONS,
        'failingPackets': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
