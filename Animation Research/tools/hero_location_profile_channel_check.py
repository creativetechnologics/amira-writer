#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_PROFILES = {
    'daylight_soft',
    'sunset_warm',
    'moonlight_blue',
    'fluorescent_clinic',
    'night_practical_mix',
}
REQUIRED_CHANNELS = {
    'ch01_world_key',
    'ch02_world_fill',
    'ch03_world_rim',
    'ch04_background_separation',
    'ch05_practical_accent',
    'ch06_atmosphere_grade',
    'ch07_luke_protect',
    'ch08_amira_protect',
}
REQUIRED_LOCATIONS = {
    'district-clinic-exterior',
    'rooftop-sunset',
    'village-street-night',
    'clinic-interior-fluorescent',
    'family-courtyard',
}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: hero_location_profile_channel_check.py <channels.json>')
        return 2
    path = Path(sys.argv[1])
    payload = json.loads(path.read_text())
    families = payload.get('channelFamilies', [])
    bindings = payload.get('locationBindings', [])

    seen_profiles = {entry.get('profileId') for entry in families}
    seen_locations = {entry.get('locationId') for entry in bindings}
    failures: list[str] = []

    for entry in families:
        channel_ids = {channel.get('channelId') for channel in entry.get('channels', [])}
        missing = REQUIRED_CHANNELS - channel_ids
        if missing:
            failures.append(f"profile:{entry.get('profileId')} missing {sorted(missing)}")
    for entry in bindings:
        fixtures = entry.get('characterFixtures', {})
        if not fixtures.get('luke') or not fixtures.get('amira'):
            failures.append(f"binding:{entry.get('locationId')} missing character fixtures")

    result = {
        'valid': seen_profiles == REQUIRED_PROFILES and seen_locations == REQUIRED_LOCATIONS and not failures,
        'missingProfiles': sorted(REQUIRED_PROFILES - seen_profiles),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen_locations),
        'failures': failures,
        'profileCount': len(families),
        'locationBindingCount': len(bindings),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
