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
ROUTING_ORDER = ['internal', 'hybrid', 'generative-assist', 'ai-video-fallback']


def profile_map(payload: dict) -> dict[str, dict]:
    return {entry.get('profileId'): entry for entry in payload.get('channelFamilies', []) if entry.get('profileId')}


def binding_map(payload: dict) -> dict[str, dict]:
    return {entry.get('locationId'): entry for entry in payload.get('locationBindings', []) if entry.get('locationId')}


def packet_map(payload: dict) -> dict[str, dict]:
    return {entry.get('locationId'): entry for entry in payload.get('packets', []) if entry.get('locationId')}


def routing_rank(value: str) -> int:
    try:
        return ROUTING_ORDER.index(value)
    except ValueError:
        return len(ROUTING_ORDER)


def add_regression(regressions: list[dict], severity: str, category: str, description: str, details: dict) -> None:
    regressions.append({
        'severity': severity,
        'category': category,
        'description': description,
        'details': details,
    })


def build_report(old_channels: dict, new_channels: dict, old_motion: dict, new_motion: dict) -> dict:
    old_profiles = profile_map(old_channels)
    new_profiles = profile_map(new_channels)
    old_bindings = binding_map(old_channels)
    new_bindings = binding_map(new_channels)
    old_packets = packet_map(old_motion)
    new_packets = packet_map(new_motion)

    regressions: list[dict] = []
    warnings: list[dict] = []

    removed_profiles = sorted(set(old_profiles) - set(new_profiles))
    if removed_profiles:
        add_regression(regressions, 'BLOCK', 'coverage', 'Lighting profile family coverage dropped', {
            'removedProfiles': removed_profiles,
        })

    removed_bindings = sorted(REQUIRED_LOCATIONS & (set(old_bindings) - set(new_bindings)))
    if removed_bindings:
        add_regression(regressions, 'BLOCK', 'coverage', 'Hero location binding coverage dropped', {
            'removedLocationBindings': removed_bindings,
        })

    removed_packets = sorted(REQUIRED_LOCATIONS & (set(old_packets) - set(new_packets)))
    if removed_packets:
        add_regression(regressions, 'BLOCK', 'coverage', 'Duet motion-lighting packet coverage dropped', {
            'removedPacketLocations': removed_packets,
        })

    for profile_id in sorted(set(old_profiles) & set(new_profiles)):
        old_channel_ids = {entry.get('channelId') for entry in old_profiles[profile_id].get('channels', [])}
        new_channel_ids = {entry.get('channelId') for entry in new_profiles[profile_id].get('channels', [])}
        missing = sorted((old_channel_ids | REQUIRED_CHANNELS) - new_channel_ids)
        if missing:
            add_regression(regressions, 'BLOCK', 'structure', f'Profile {profile_id} lost required lighting channels', {
                'profileId': profile_id,
                'missingChannels': missing,
            })

    for location_id in sorted(REQUIRED_LOCATIONS & set(old_bindings) & set(new_bindings)):
        old_binding = old_bindings[location_id]
        new_binding = new_bindings[location_id]
        old_default = old_binding.get('defaultProfile')
        new_default = new_binding.get('defaultProfile')
        if old_default != new_default:
            warnings.append({
                'severity': 'WARN',
                'category': 'default-profile',
                'description': f'{location_id} changed default lighting profile',
                'details': {'from': old_default, 'to': new_default},
            })
        for character_id in ('luke', 'amira'):
            if character_id not in new_binding.get('characterFixtures', {}):
                add_regression(regressions, 'BLOCK', 'fixture-mapping', f'{location_id} lost {character_id} character fixture binding', {
                    'locationId': location_id,
                    'characterId': character_id,
                })

    for location_id in sorted(REQUIRED_LOCATIONS & set(old_packets) & set(new_packets)):
        old_packet = old_packets[location_id]
        new_packet = new_packets[location_id]
        if 'lightingPlanFixture' not in new_packet or 'duetLightingPacketFixture' not in new_packet:
            add_regression(regressions, 'BLOCK', 'fixture-mapping', f'{location_id} lost packet fixture linkage', {
                'locationId': location_id,
                'hasLightingPlanFixture': 'lightingPlanFixture' in new_packet,
                'hasDuetLightingPacketFixture': 'duetLightingPacketFixture' in new_packet,
            })
        old_beat_count = len(old_packet.get('motionBeats', []))
        new_beat_count = len(new_packet.get('motionBeats', []))
        if new_beat_count < 2:
            add_regression(regressions, 'BLOCK', 'coverage', f'{location_id} dropped below minimum duet beat coverage', {
                'oldBeatCount': old_beat_count,
                'newBeatCount': new_beat_count,
            })
        elif new_beat_count < old_beat_count:
            warnings.append({
                'severity': 'WARN',
                'category': 'coverage',
                'description': f'{location_id} lost duet motion beats',
                'details': {'oldBeatCount': old_beat_count, 'newBeatCount': new_beat_count},
            })
        old_routing = old_packet.get('routingMode')
        new_routing = new_packet.get('routingMode')
        if routing_rank(new_routing) > routing_rank(old_routing):
            warnings.append({
                'severity': 'WARN',
                'category': 'routing',
                'description': f'{location_id} routing downgraded',
                'details': {'from': old_routing, 'to': new_routing},
            })

    return {
        'summary': {
            'removedProfiles': removed_profiles,
            'removedLocationBindings': removed_bindings,
            'removedPacketLocations': removed_packets,
            'oldProfileCount': len(old_profiles),
            'newProfileCount': len(new_profiles),
            'oldPacketCount': len(old_packets),
            'newPacketCount': len(new_packets),
        },
        'regressions': regressions,
        'warnings': warnings,
        'hasRegression': bool(regressions),
    }


def main() -> int:
    if len(sys.argv) != 5:
        print('Usage: lighting_fixture_diff_report.py <old-channels.json> <new-channels.json> <old-motion.json> <new-motion.json>')
        return 2
    old_channels = json.loads(Path(sys.argv[1]).read_text())
    new_channels = json.loads(Path(sys.argv[2]).read_text())
    old_motion = json.loads(Path(sys.argv[3]).read_text())
    new_motion = json.loads(Path(sys.argv[4]).read_text())
    report = build_report(old_channels, new_channels, old_motion, new_motion)
    print(json.dumps(report, indent=2))
    return 1 if report['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
