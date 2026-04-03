#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

from ensemble_beat_lighting_readiness_report import analyze

ROUTING_ORDER = ['internal', 'hybrid', 'ai-video-fallback']


def beat_map(payload: dict) -> dict[str, dict]:
    return {beat.get('beatId'): beat for beat in payload.get('beats', []) if beat.get('beatId')}


def routing_rank(value: str) -> int:
    try:
        return ROUTING_ORDER.index(value)
    except ValueError:
        return len(ROUTING_ORDER)


def report(old: dict, new: dict) -> dict:
    regressions: list[dict] = []
    warnings: list[dict] = []

    old_summary = analyze(old)
    new_summary = analyze(new)

    if old.get('sharedLightWorld') != new.get('sharedLightWorld'):
        regressions.append({
            'severity': 'BLOCK',
            'description': 'Shared light world changed',
            'details': {'from': old.get('sharedLightWorld'), 'to': new.get('sharedLightWorld')},
        })

    old_participants = {item.get('participantId'): item for item in old.get('participants', []) if item.get('participantId')}
    new_participants = {item.get('participantId'): item for item in new.get('participants', []) if item.get('participantId')}
    removed_participants = sorted(set(old_participants) - set(new_participants))
    if removed_participants:
        regressions.append({
            'severity': 'BLOCK',
            'description': 'Participant coverage dropped',
            'details': {'removedParticipants': removed_participants},
        })
    if len(new_participants) < len(old_participants):
        warnings.append({
            'severity': 'WARN',
            'description': 'Participant count decreased',
            'details': {'from': len(old_participants), 'to': len(new_participants)},
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
        old_required = set(old_beat.get('requiredProtectedParticipants') or old_beat.get('focusParticipants') or [])
        new_protections = set(new_beat.get('activeProtectionChannels', []))
        new_participant_map = {item.get('participantId'): item for item in new.get('participants', []) if item.get('participantId')}

        missing_required = []
        for participant_id in old_required:
            participant = new_participant_map.get(participant_id)
            if not participant:
                missing_required.append(f'{participant_id}:missing-participant')
                continue
            protect_channel = participant.get('protectChannel')
            if protect_channel not in new_protections:
                missing_required.append(protect_channel or f'{participant_id}:missing-channel')
        if missing_required:
            regressions.append({
                'severity': 'BLOCK',
                'description': f'{beat_id} lost required participant protection',
                'details': {'missingRequiredProtection': missing_required},
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

    old_route = old_summary.get('recommendedRouting')
    new_route = new_summary.get('recommendedRouting')
    if routing_rank(new_route) > routing_rank(old_route):
        if new_route == 'ai-video-fallback':
            regressions.append({
                'severity': 'BLOCK',
                'description': 'Routing pressure worsened to ai-video-fallback',
                'details': {'from': old_route, 'to': new_route},
            })
        else:
            warnings.append({
                'severity': 'WARN',
                'description': 'Routing pressure increased',
                'details': {'from': old_route, 'to': new_route},
            })

    for participant_id, old_cov in old_summary.get('perParticipantCoverage', {}).items():
        new_cov = new_summary.get('perParticipantCoverage', {}).get(participant_id, 0.0)
        if new_cov < old_cov:
            warnings.append({
                'severity': 'WARN',
                'description': f'{participant_id} protection coverage decreased',
                'details': {'from': old_cov, 'to': new_cov},
            })

    return {
        'summary': {
            'oldBeatCount': len(old_beats),
            'newBeatCount': len(new_beats),
            'removedBeats': removed_beats,
            'oldParticipantCount': len(old_participants),
            'newParticipantCount': len(new_participants),
            'oldRecommendedRouting': old_route,
            'newRecommendedRouting': new_route,
        },
        'oldReadiness': old_summary,
        'newReadiness': new_summary,
        'regressions': regressions,
        'warnings': warnings,
        'hasRegression': bool(regressions),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: ensemble_beat_lighting_diff_report.py <old.json> <new.json>')
        return 2
    old = json.loads(Path(sys.argv[1]).read_text())
    new = json.loads(Path(sys.argv[2]).read_text())
    payload = report(old, new)
    print(json.dumps(payload, indent=2))
    return 1 if payload['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
