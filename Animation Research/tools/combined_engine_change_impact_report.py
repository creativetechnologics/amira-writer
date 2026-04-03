#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

BAND_ORDER = ['B1', 'B2', 'B3', 'B4', 'B5', 'B6']


def band_index_map(bands: list[dict]) -> dict[str, int]:
    ordered = [band.get('id') for band in bands if band.get('id')]
    return {band_id: idx for idx, band_id in enumerate(ordered)}


def reentry_rule(change_type: str, subsystem: str) -> tuple[str, str]:
    if change_type in {'schema-change', 'adapter-contract-change'}:
        return 'B1', 'Shared contracts and schema changes require reopening the rollout from the foundation band.'
    if change_type in {'runtime-contract-change', 'runtime-behavior-change'}:
        if subsystem == 'mouth':
            return 'B3', 'Mouth runtime changes first become execution-critical in the singing/readability band.'
        if subsystem == 'lighting':
            return 'B2', 'Lighting runtime changes affect the deterministic pilot before later routing bands.'
        return 'B2', 'Body/shared runtime changes affect the deterministic pilot and every later band.'
    if change_type in {'validation-rule-change', 'governance-rule-change'}:
        if subsystem == 'mouth':
            return 'B3', 'Mouth validation rules first gate the singing/readability band.'
        if subsystem == 'lighting':
            return 'B3', 'Lighting validation rules first gate the readability and beat-lighting layer.'
        if subsystem == 'body':
            return 'B2', 'Body validation rules first gate the single-character pilot band.'
        return 'B1', 'Shared validation and governance changes must reopen the rollout from the first governance layer.'
    return 'B1', 'Unknown change classes default to the safest re-entry point at the foundation band.'


def outputs_for_bands(matrix: dict, reopened_bands: list[str]) -> list[str]:
    outputs: set[str] = set()
    for band in matrix.get('bands', []):
        band_id = band.get('id')
        if band_id not in reopened_bands:
            continue
        for subsystem in ('body', 'mouth', 'lighting'):
            outputs.update(band.get(subsystem, {}).get('requiredOutputs', []))
    return sorted(outputs)


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: combined_engine_change_impact_report.py <change-events.json> <rollout-matrix.json> <work-packages.json>')
        return 2

    events = json.loads(Path(sys.argv[1]).read_text())
    matrix = json.loads(Path(sys.argv[2]).read_text())
    work_packages = json.loads(Path(sys.argv[3]).read_text())

    work_package_map = {item.get('workPackageId'): item for item in work_packages.get('workPackages', []) if item.get('workPackageId')}
    by_band: dict[str, list[str]] = {}
    for pkg_id, item in work_package_map.items():
        by_band.setdefault(item.get('bandId', ''), []).append(pkg_id)

    order = [band.get('id') for band in matrix.get('bands', []) if band.get('id')]
    band_to_index = band_index_map(matrix.get('bands', []))
    invalid: list[str] = []
    impact_matrix = []

    for event in events.get('changeEvents', []):
        event_id = event.get('eventId')
        change_type = event.get('changeType', '')
        subsystem = event.get('subsystem', '')
        reentry_band, rationale = reentry_rule(change_type, subsystem)
        if reentry_band not in band_to_index:
            invalid.append(f'{event_id}:invalid-reentry-band:{reentry_band}')
            continue
        reopened = order[band_to_index[reentry_band]:]
        impacted_packages = []
        for band_id in reopened:
            impacted_packages.extend(sorted(by_band.get(band_id, [])))
        impact_matrix.append({
            'eventId': event_id,
            'changeType': change_type,
            'subsystem': subsystem,
            'reentryBand': reentry_band,
            'reopenedBands': reopened,
            'impactedWorkPackages': impacted_packages,
            'recheckOutputs': outputs_for_bands(matrix, reopened),
            'rationale': rationale,
        })

    minimum_reentry = None
    if impact_matrix:
        minimum_reentry = min(impact_matrix, key=lambda item: band_to_index[item['reentryBand']])['reentryBand']
    reopened_bands = sorted({band for item in impact_matrix for band in item['reopenedBands']}, key=lambda band: band_to_index[band]) if impact_matrix else []

    result = {
        'eventCount': len(impact_matrix),
        'minimumReentryBand': minimum_reentry,
        'impactMatrix': impact_matrix,
        'bandsReopened': reopened_bands,
        'valid': not invalid and len(impact_matrix) == len(events.get('changeEvents', [])),
    }
    if invalid:
        result['invalidEvents'] = invalid
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
