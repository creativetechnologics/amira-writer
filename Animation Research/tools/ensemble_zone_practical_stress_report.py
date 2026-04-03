#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def clamp(value: float) -> float:
    return max(0.0, min(1.0, value))


def beat_stress(beat: dict, participant_count: int) -> float:
    zone_pressure = max(0.0, (float(beat.get('activeZoneCount', 0)) - 1.0) / 4.0)
    practical_pressure = float(beat.get('activePracticalCount', 0)) / 3.0
    moving_practical_pressure = float(beat.get('movingPracticalCount', 0)) / 2.0
    occlusion_pressure = float(beat.get('occlusionRisk', 0.0))
    key_instability = 1.0 - float(beat.get('worldKeyStability', 0.0))
    density_pressure = max(0.0, (participant_count - 2) / 4.0)
    return clamp(
        zone_pressure * 0.22
        + practical_pressure * 0.18
        + moving_practical_pressure * 0.20
        + occlusion_pressure * 0.20
        + key_instability * 0.10
        + density_pressure * 0.10
    )


def minimum_routing(max_stress: float, participant_count: int, lowest_stability: float) -> str:
    if participant_count >= 5 and max_stress >= 0.72:
        return 'ai-video-fallback'
    if lowest_stability < 0.75 and max_stress >= 0.68:
        return 'ai-video-fallback'
    if participant_count >= 4 and max_stress >= 0.30:
        return 'hybrid'
    return 'internal'


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: ensemble_zone_practical_stress_report.py <cases.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    case_summaries = []
    internal_safe = []
    hybrid_pressure = []
    fallback_pressure = []
    valid = True

    for case in payload.get('cases', []):
        shot_id = case.get('shotId', 'unknown')
        location_id = case.get('locationId', 'unknown')
        participant_count = int(case.get('participantCount', 0))
        beats = case.get('beats', [])
        blocking = []
        warnings = []
        if participant_count <= 0:
            blocking.append('missing-or-invalid-participant-count')
        if not beats:
            blocking.append('missing-beats')

        beat_scores = []
        lowest_stability = 1.0
        for beat in beats:
            stability = float(beat.get('worldKeyStability', 0.0))
            lowest_stability = min(lowest_stability, stability)
            if stability <= 0.0:
                blocking.append(f"{beat.get('beatId','unknown')}:missing-world-key-stability")
            score = beat_stress(beat, participant_count)
            beat_scores.append(score)
            if participant_count >= 4 and int(beat.get('activeZoneCount', 0)) >= 3 and int(beat.get('activePracticalCount', 0)) >= 2:
                warnings.append(f"{beat.get('beatId','unknown')}:ensemble-zone-practical-density")

        max_stress = max(beat_scores) if beat_scores else 1.0
        route = minimum_routing(max_stress, participant_count, lowest_stability)
        if route == 'internal':
            internal_safe.append(location_id)
        elif route == 'hybrid':
            hybrid_pressure.append(location_id)
        else:
            fallback_pressure.append(location_id)
        if blocking:
            valid = False

        case_summaries.append({
            'shotId': shot_id,
            'locationId': location_id,
            'participantCount': participant_count,
            'maxBeatStress': round(max_stress, 3),
            'recommendedMinimumRouting': route,
            'blockingIssues': blocking,
            'warnings': warnings,
        })

    result = {
        'caseCount': len(case_summaries),
        'internalSafeCases': sorted(internal_safe),
        'hybridPressureCases': sorted(hybrid_pressure),
        'fallbackPressureCases': sorted(fallback_pressure),
        'caseSummaries': case_summaries,
        'valid': valid,
    }
    print(json.dumps(result, indent=2))
    return 0 if valid else 1


if __name__ == '__main__':
    raise SystemExit(main())
