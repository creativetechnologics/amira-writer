#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Iterable

READINESS_SCORE = {
    'draft': 0.0,
    'blocking-ready': 0.35,
    'dialogue-ready': 0.65,
    'performance-ready': 0.85,
    'production-ready': 1.0,
}


def ratio(hit: int, total: int) -> float:
    return 1.0 if total <= 0 else max(0.0, min(1.0, hit / total))


def slugify(value: str) -> str:
    return value.lower().replace(' ', '-').replace('_', '-')


def infer_character_channel_map(characters: Iterable[str]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for character_id in characters:
        slug = slugify(character_id)
        if 'luke' in slug:
            mapping[character_id] = 'ch07_luke_protect'
        elif 'amira' in slug:
            mapping[character_id] = 'ch08_amira_protect'
    return mapping


def expected_focus_characters(focus_value: object, known_characters: list[str]) -> list[str]:
    if focus_value is None:
        return known_characters
    if isinstance(focus_value, list):
        result = [item for item in focus_value if isinstance(item, str)]
        return result or known_characters
    if not isinstance(focus_value, str):
        return known_characters
    normalized = slugify(focus_value)
    if normalized in {'both', 'all', 'ensemble', 'duet'}:
        return known_characters
    matched = [
        character_id
        for character_id in known_characters
        if slugify(character_id) == normalized
        or slugify(character_id).startswith(f'{normalized}-')
        or normalized in slugify(character_id)
    ]
    return matched or [focus_value]


def recommended_routing(
    weighted: float,
    location_id: str,
    revision_sensitivity: int,
    package_score: float,
    package_floor: float,
    blocking_count: int,
) -> str:
    if blocking_count > 0 or weighted < 0.45 or package_score < 0.50 or package_floor < 0.50:
        return 'ai-video-fallback'
    if location_id == 'village-street-night':
        return 'hybrid'
    if weighted >= 0.85 and package_floor >= 0.65 and revision_sensitivity >= 7:
        return 'internal'
    if weighted >= 0.60:
        return 'hybrid'
    return 'ai-video-fallback'


def readiness_tier(weighted: float, blocking_count: int, package_floor: float) -> str:
    if blocking_count > 0 or package_floor < 0.50 or weighted < 0.45:
        return 'fallback-only'
    if weighted >= 0.85 and package_floor >= 0.65:
        return 'internal-ready'
    if weighted >= 0.60:
        return 'hybrid-ready'
    return 'fallback-only'


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: beat_lighting_readiness_report.py <fixture.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    beats = payload.get('beats', [])
    package_readiness = payload.get('packageReadiness', {})
    known_characters = list(package_readiness.keys())
    declared_character_count = int(payload.get('characterCount', len(known_characters)))
    continuity_hits = 0
    protection_hits = 0
    practical_hits = 0
    character_focus_hits = 0
    blocking: list[str] = []
    warnings: list[str] = []
    protect_map = payload.get('characterProtectChannels', {})
    if not protect_map:
        protect_map = infer_character_channel_map(known_characters)
        warnings.append('characterProtectChannels missing; using inferred fallback mapping')
    if len(known_characters) != declared_character_count:
        warnings.append('characterCount does not match packageReadiness key count')
    missing_character_mappings = sorted(character_id for character_id in known_characters if character_id not in protect_map)
    if missing_character_mappings:
        warnings.append(f"missing characterProtectChannels for: {', '.join(missing_character_mappings)}")

    per_character_focus_hits = {character_id: 0 for character_id in known_characters}
    per_character_focus_total = {character_id: 0 for character_id in known_characters}

    if not payload.get('sharedLightWorld'):
        blocking.append('missing-shared-light-world')

    for beat in beats:
        notes = beat.get('continuityNotes', [])
        protections = beat.get('activeProtectionChannels', [])
        if 'shared light world remains unchanged' in notes:
            continuity_hits += 1
        else:
            blocking.append(f"{beat.get('beatId','unknown')}:missing-shared-world-note")

        focus_characters = expected_focus_characters(beat.get('focusCharacter'), known_characters)
        expected_channels = []
        for character_id in focus_characters:
            channel = protect_map.get(character_id)
            if channel:
                expected_channels.append(channel)
            if character_id in per_character_focus_total:
                per_character_focus_total[character_id] += 1

        missing_beat_channels = [channel for channel in expected_channels if channel not in protections]
        if expected_channels and not missing_beat_channels:
            protection_hits += 1
            character_focus_hits += 1
            for character_id in focus_characters:
                channel = protect_map.get(character_id)
                if channel and channel in protections and character_id in per_character_focus_hits:
                    per_character_focus_hits[character_id] += 1
        else:
            if expected_channels:
                blocking.append(f"{beat.get('beatId','unknown')}:missing-protection:{','.join(missing_beat_channels or expected_channels)}")
            else:
                warnings.append(f"{beat.get('beatId','unknown')}:no-protection-expectation-derived")

        hijack = False
        for practical, channels in beat.get('activePracticalChannels', {}).items():
            if 'ch01_world_key' in channels:
                blocking.append(f"{beat.get('beatId','unknown')}:practical-uses-world-key:{practical}")
                hijack = True
        if not hijack:
            practical_hits += 1
    package_values = [READINESS_SCORE.get(v, 0.0) for v in package_readiness.values()]
    package_score = sum(package_values) / len(package_values) if package_values else 0.0
    package_floor = min(package_values) if package_values else 0.0
    continuity_score = ratio(continuity_hits, len(beats))
    protection_score = ratio(protection_hits, len(beats))
    practical_score = ratio(practical_hits, len(beats))
    focus_character_score = ratio(
        sum(per_character_focus_hits.values()),
        sum(per_character_focus_total.values()),
    )
    weighted = (
        continuity_score * 0.30
        + protection_score * 0.20
        + practical_score * 0.10
        + package_score * 0.20
        + focus_character_score * 0.20
    )
    route = recommended_routing(
        weighted,
        payload.get('locationId', ''),
        int(payload.get('revisionSensitivity', 0)),
        package_score,
        package_floor,
        len(blocking),
    )
    if route == 'hybrid' and payload.get('locationId') == 'village-street-night':
        warnings.append('night practical complexity keeps this location hybrid-biased')
    tier = readiness_tier(weighted, len(blocking), package_floor)
    result = {
        'shotId': payload.get('shotId'),
        'locationId': payload.get('locationId'),
        'characterCount': declared_character_count,
        'continuityScore': round(continuity_score, 3),
        'protectionScore': round(protection_score, 3),
        'practicalScore': round(practical_score, 3),
        'focusCharacterScore': round(focus_character_score, 3),
        'packageScore': round(package_score, 3),
        'packageFloor': round(package_floor, 3),
        'weightedScore': round(weighted, 3),
        'readinessTier': tier,
        'recommendedRouting': route,
        'characterProtectChannels': protect_map,
        'perCharacterFocusCoverage': {
            character_id: round(ratio(per_character_focus_hits[character_id], per_character_focus_total[character_id]), 3)
            for character_id in known_characters
        },
        'blockingIssues': blocking,
        'warnings': warnings,
        'valid': not blocking,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
