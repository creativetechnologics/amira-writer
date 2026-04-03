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
        print('Usage: duet_routing_comparison_report.py <comparisons.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    comparisons = payload.get('comparisons', [])
    seen_locations = set()
    invalid: list[str] = []
    baseline_counts = {'internal': 0, 'hybrid': 0, 'ai-video-fallback': 0}
    fallback_only = []

    for item in comparisons:
        location_id = item.get('locationId', 'unknown')
        if location_id:
            seen_locations.add(location_id)
        modes = {entry.get('mode') for entry in item.get('routeOptions', [])}
        if not item.get('lightingProfile') or not item.get('sharedLightWorld') or not item.get('baselineRecommendation'):
            invalid.append(location_id)
            continue
        if REQUIRED_MODES - modes:
            invalid.append(location_id)
            continue
        baseline = item.get('baselineRecommendation')
        if baseline in baseline_counts:
            baseline_counts[baseline] += 1
        if baseline == 'ai-video-fallback':
            fallback_only.append(location_id)

    report = {
        'comparisonCount': len(comparisons),
        'missingLocations': sorted(REQUIRED_LOCATIONS - seen_locations),
        'baselineCounts': baseline_counts,
        'fallbackBaselines': sorted(fallback_only),
        'valid': not invalid and seen_locations == REQUIRED_LOCATIONS,
        'invalidComparisons': invalid,
    }
    print(json.dumps(report, indent=2))
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
