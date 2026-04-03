#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

READINESS_SCORE = {
    'draft': 0.0,
    'blocking-ready': 0.35,
    'dialogue-ready': 0.65,
    'performance-ready': 0.85,
    'production-ready': 1.0,
}


def ratio(hit: int, total: int) -> float:
    return 1.0 if total <= 0 else max(0.0, min(1.0, hit / total))


def ensemble_density_score(participant_count: int) -> float:
    if participant_count <= 2:
        return 1.0
    if participant_count == 3:
        return 0.9
    if participant_count == 4:
        return 0.8
    if participant_count == 5:
        return 0.7
    return 0.55


def readiness_tier(weighted: float, blocking_count: int, package_floor: float) -> str:
    if blocking_count > 0 or package_floor < 0.35 or weighted < 0.45:
        return 'fallback-only'
    if weighted >= 0.86 and package_floor >= 0.65:
        return 'internal-ready'
    if weighted >= 0.62:
        return 'hybrid-ready'
    return 'fallback-only'


def recommended_routing(
    readiness_tier_value: str,
    location_id: str,
    participant_count: int,
    revision_sensitivity: int,
) -> str:
    if readiness_tier_value == 'fallback-only':
        return 'ai-video-fallback'
    if location_id == 'village-street-night':
        return 'hybrid'
    if participant_count >= 5:
        return 'hybrid' if revision_sensitivity >= 6 else 'ai-video-fallback'
    if readiness_tier_value == 'internal-ready' and participant_count <= 4 and revision_sensitivity >= 8:
        return 'internal'
    return 'hybrid'


def analyze(payload: dict) -> dict:
    participants = payload.get('participants', [])
    beats = payload.get('beats', [])

    continuity_hits = 0
    focus_protection_hits = 0
    ensemble_protection_hits = 0
    practical_hits = 0
    blocking: list[str] = []
    warnings: list[str] = []

    participant_map = {item.get('participantId'): item for item in participants if item.get('participantId')}
    participant_count = len(participant_map)
    per_participant_required = {participant_id: 0 for participant_id in participant_map}
    per_participant_hits = {participant_id: 0 for participant_id in participant_map}

    if not payload.get('sharedLightWorld'):
        blocking.append('missing-shared-light-world')

    readiness_values = []
    for participant_id, participant in participant_map.items():
        readiness = participant.get('packageReadiness', 'draft')
        readiness_value = READINESS_SCORE.get(readiness, 0.0)
        readiness_values.append(readiness_value)
        if readiness_value <= 0.0:
            blocking.append(f'{participant_id}:package-below-blocking-ready')
        if not participant.get('protectChannel'):
            blocking.append(f'{participant_id}:missing-protect-channel')

    for beat in beats:
        beat_id = beat.get('beatId', 'unknown')
        notes = beat.get('continuityNotes', [])
        protections = set(beat.get('activeProtectionChannels', []))
        required = beat.get('requiredProtectedParticipants') or beat.get('focusParticipants') or []

        if 'shared light world remains unchanged' in notes:
            continuity_hits += 1
        else:
            blocking.append(f'{beat_id}:missing-shared-world-note')

        missing_focus_channels: list[str] = []
        for participant_id in required:
            participant = participant_map.get(participant_id)
            if not participant:
                warnings.append(f'{beat_id}:unknown-participant:{participant_id}')
                continue
            per_participant_required[participant_id] += 1
            protect_channel = participant.get('protectChannel')
            if protect_channel in protections:
                per_participant_hits[participant_id] += 1
            else:
                missing_focus_channels.append(protect_channel or f'{participant_id}:missing-channel')

        if required and not missing_focus_channels:
            focus_protection_hits += 1
            ensemble_protection_hits += 1
        else:
            if missing_focus_channels:
                blocking.append(f'{beat_id}:missing-required-protection:{",".join(missing_focus_channels)}')
            elif not required:
                warnings.append(f'{beat_id}:no-required-protected-participants')

        hijack = False
        for practical, channels in beat.get('activePracticalChannels', {}).items():
            if 'ch01_world_key' in channels:
                blocking.append(f'{beat_id}:practical-uses-world-key:{practical}')
                hijack = True
        if not hijack:
            practical_hits += 1

    package_score = sum(readiness_values) / len(readiness_values) if readiness_values else 0.0
    package_floor = min(readiness_values) if readiness_values else 0.0
    continuity_score = ratio(continuity_hits, len(beats))
    focus_protection_score = ratio(focus_protection_hits, len(beats))
    ensemble_protection_score = ratio(ensemble_protection_hits, len(beats))
    practical_score = ratio(practical_hits, len(beats))
    density_score = ensemble_density_score(participant_count)

    weighted = (
        continuity_score * 0.24
        + focus_protection_score * 0.20
        + ensemble_protection_score * 0.16
        + practical_score * 0.10
        + package_score * 0.20
        + density_score * 0.10
    )
    tier = readiness_tier(weighted, len(blocking), package_floor)
    route = recommended_routing(
        tier,
        payload.get('locationId', ''),
        participant_count,
        int(payload.get('revisionSensitivity', 0)),
    )

    result = {
        'shotId': payload.get('shotId'),
        'locationId': payload.get('locationId'),
        'participantCount': participant_count,
        'continuityScore': round(continuity_score, 3),
        'focusProtectionScore': round(focus_protection_score, 3),
        'ensembleProtectionScore': round(ensemble_protection_score, 3),
        'practicalScore': round(practical_score, 3),
        'packageScore': round(package_score, 3),
        'packageFloor': round(package_floor, 3),
        'ensembleDensityScore': round(density_score, 3),
        'weightedScore': round(weighted, 3),
        'readinessTier': tier,
        'recommendedRouting': route,
        'perParticipantCoverage': {
            participant_id: round(ratio(per_participant_hits[participant_id], per_participant_required[participant_id]), 3)
            for participant_id in participant_map
        },
        'blockingIssues': blocking,
        'warnings': warnings,
        'valid': not blocking,
    }
    if route == 'hybrid' and participant_count >= 4:
        result['warnings'].append('ensemble density keeps this shot hybrid-biased')
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: ensemble_beat_lighting_readiness_report.py <fixture.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    result = analyze(payload)
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
