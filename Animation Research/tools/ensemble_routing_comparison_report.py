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
REQUIRED_MODES = {'internal', 'hybrid', 'ai-video-fallback'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: ensemble_routing_comparison_report.py <comparisons.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    comparisons = payload.get('comparisons', [])
    seen_locations = set()
    invalid: list[str] = []
    baseline_counts = {'internal': 0, 'hybrid': 0, 'ai-video-fallback': 0}
    internal_capable: list[str] = []
    hybrid_biased: list[str] = []
    fallback_baselines: list[str] = []

    for item in comparisons:
        location_id = item.get('locationId', 'unknown')
        seen_locations.add(location_id)
        participant_count = int(item.get('participantCount', 0))
        baseline = item.get('baselineRecommendation')
        route_options = item.get('routeOptions', [])
        modes = {entry.get('mode') for entry in route_options}

        if (
            not item.get('lightingProfile')
            or not item.get('sharedLightWorld')
            or not baseline
            or participant_count <= 0
            or REQUIRED_MODES - modes
        ):
            invalid.append(location_id)
            continue

        if baseline in baseline_counts:
            baseline_counts[baseline] += 1
        if any(entry.get('mode') == 'internal' for entry in route_options):
            internal_capable.append(location_id)
        if baseline == 'hybrid':
            hybrid_biased.append(location_id)
        if baseline == 'ai-video-fallback':
            fallback_baselines.append(location_id)

        if participant_count >= 5 and baseline == 'internal':
            invalid.append(f'{location_id}:internal-baseline-too-dense')
        if location_id == 'village-street-night' and baseline == 'internal':
            invalid.append(f'{location_id}:night-ensemble-should-not-baseline-internal')

    report = {
        'comparisonCount': len(comparisons),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen_locations),
        'baselineCounts': baseline_counts,
        'internalCapableLocations': sorted(set(internal_capable)),
        'hybridBiasedLocations': sorted(set(hybrid_biased)),
        'fallbackBaselines': sorted(set(fallback_baselines)),
        'valid': not invalid and seen_locations == REQUIRED_LOCATIONS,
        'invalidComparisons': invalid,
    }
    print(json.dumps(report, indent=2))
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
