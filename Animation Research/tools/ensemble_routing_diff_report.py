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
ROUTING_ORDER = ['internal', 'hybrid', 'ai-video-fallback']


def comparison_map(payload: dict) -> dict[str, dict]:
    return {entry.get('locationId'): entry for entry in payload.get('comparisons', []) if entry.get('locationId')}


def routing_rank(value: str) -> int:
    try:
        return ROUTING_ORDER.index(value)
    except ValueError:
        return len(ROUTING_ORDER)


def add_issue(items: list[dict], severity: str, category: str, description: str, details: dict) -> None:
    items.append({
        'severity': severity,
        'category': category,
        'description': description,
        'details': details,
    })


def build_report(old_payload: dict, new_payload: dict) -> dict:
    old_map = comparison_map(old_payload)
    new_map = comparison_map(new_payload)
    regressions: list[dict] = []
    warnings: list[dict] = []

    removed_locations = sorted(REQUIRED_LOCATIONS & (set(old_map) - set(new_map)))
    if removed_locations:
        add_issue(regressions, 'BLOCK', 'coverage', 'Ensemble routing location coverage dropped', {
            'removedLocations': removed_locations,
        })

    for location_id in sorted(REQUIRED_LOCATIONS & set(old_map) & set(new_map)):
        old_item = old_map[location_id]
        new_item = new_map[location_id]
        old_modes = {entry.get('mode') for entry in old_item.get('routeOptions', [])}
        new_modes = {entry.get('mode') for entry in new_item.get('routeOptions', [])}
        missing_modes = sorted(REQUIRED_MODES - new_modes)
        if missing_modes:
            add_issue(regressions, 'BLOCK', 'coverage', f'{location_id} lost required routing modes', {
                'missingModes': missing_modes,
            })

        old_baseline = old_item.get('baselineRecommendation')
        new_baseline = new_item.get('baselineRecommendation')
        if routing_rank(new_baseline) > routing_rank(old_baseline):
            if new_baseline == 'ai-video-fallback':
                add_issue(regressions, 'BLOCK', 'routing', f'{location_id} baseline collapsed to ai-video-fallback', {
                    'from': old_baseline,
                    'to': new_baseline,
                })
            else:
                warnings.append({
                    'severity': 'WARN',
                    'category': 'routing',
                    'description': f'{location_id} baseline downgraded',
                    'details': {'from': old_baseline, 'to': new_baseline},
                })

        participant_count = int(new_item.get('participantCount', 0))
        old_participant_count = int(old_item.get('participantCount', 0))
        if participant_count < old_participant_count:
            warnings.append({
                'severity': 'WARN',
                'category': 'density',
                'description': f'{location_id} participant count dropped',
                'details': {'from': old_participant_count, 'to': participant_count},
            })
        if participant_count >= 5 and new_baseline == 'internal':
            add_issue(regressions, 'BLOCK', 'routing', f'{location_id} should not baseline internal at 5+ participants', {
                'participantCount': participant_count,
                'baseline': new_baseline,
            })
        if location_id == 'village-street-night' and new_baseline == 'internal':
            add_issue(regressions, 'BLOCK', 'routing', 'village-street-night ensemble should remain hybrid-biased', {
                'baseline': new_baseline,
            })

        old_reasons = len(old_item.get('decisionReasons', []))
        new_reasons = len(new_item.get('decisionReasons', []))
        if new_reasons < old_reasons:
            warnings.append({
                'severity': 'WARN',
                'category': 'rationale',
                'description': f'{location_id} decision rationale shrank',
                'details': {'from': old_reasons, 'to': new_reasons},
            })

    return {
        'summary': {
            'oldComparisonCount': len(old_map),
            'newComparisonCount': len(new_map),
            'removedLocations': removed_locations,
        },
        'regressions': regressions,
        'warnings': warnings,
        'hasRegression': bool(regressions),
    }


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: ensemble_routing_diff_report.py <old.json> <new.json>')
        return 2
    old_payload = json.loads(Path(sys.argv[1]).read_text())
    new_payload = json.loads(Path(sys.argv[2]).read_text())
    report = build_report(old_payload, new_payload)
    print(json.dumps(report, indent=2))
    return 1 if report['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
