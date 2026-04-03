#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ROUTING_ORDER = ['internal', 'hybrid', 'ai-video-fallback']


def routing_rank(value: str) -> int:
    try:
        return ROUTING_ORDER.index(value)
    except ValueError:
        return len(ROUTING_ORDER)


def most_conservative(*values: str) -> str:
    return max(values, key=routing_rank)


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: ensemble_layer_consistency_report.py <cases.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    blocking_locations: list[str] = []
    warning_locations: list[str] = []
    case_summaries = []

    for item in payload.get('cases', []):
        location_id = item.get('locationId', 'unknown')
        readiness = item.get('readinessRecommendedRouting')
        baseline = item.get('comparisonBaselineRouting')
        stress = item.get('stressMinimumRouting')
        consensus = most_conservative(readiness, baseline, stress)
        blocking: list[str] = []
        warnings: list[str] = []

        if routing_rank(readiness) < routing_rank(stress):
            blocking.append('readiness route is less conservative than stress minimum')
        if routing_rank(baseline) < routing_rank(stress):
            blocking.append('baseline route is less conservative than stress minimum')
        if readiness != baseline and not blocking:
            warnings.append('readiness and baseline routes disagree')
        if routing_rank(baseline) > routing_rank(readiness):
            warnings.append('baseline is more conservative than readiness')

        if blocking:
            blocking_locations.append(location_id)
        elif warnings:
            warning_locations.append(location_id)

        case_summaries.append({
            'locationId': location_id,
            'readinessRecommendedRouting': readiness,
            'comparisonBaselineRouting': baseline,
            'stressMinimumRouting': stress,
            'consensusMinimumRouting': consensus,
            'blockingIssues': blocking,
            'warnings': warnings,
        })

    result = {
        'caseCount': len(case_summaries),
        'blockingLocations': sorted(blocking_locations),
        'warningLocations': sorted(warning_locations),
        'caseSummaries': case_summaries,
        'valid': len(blocking_locations) == 0,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
