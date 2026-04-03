#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

GLOBAL_VALIDATION_ARTIFACTS = [
    'combined_engine_program_gate.json',
    'combined_engine_band_exit_report.json',
    'combined_engine_change_impact_report.json',
]


def reentry_rule(change_type: str, subsystem: str) -> tuple[str, str]:
    if change_type in {'schema-change', 'adapter-contract-change'}:
        return 'B1', 'Shared contracts and schema changes reopen the rollout from the foundation band.'
    if change_type in {'runtime-contract-change', 'runtime-behavior-change'}:
        if subsystem == 'mouth':
            return 'B3', 'Mouth runtime changes first become execution-critical in the singing/readability band.'
        if subsystem == 'lighting':
            return 'B2', 'Lighting runtime changes affect the deterministic pilot before later routing bands.'
        return 'B2', 'Body/shared runtime changes affect the deterministic pilot and every later band.'
    if change_type in {'validation-rule-change', 'governance-rule-change'}:
        if subsystem == 'mouth':
            return 'B3', 'Mouth validation changes first gate the singing/readability band.'
        if subsystem == 'lighting':
            return 'B3', 'Lighting validation changes first gate the readability and beat-lighting layer.'
        if subsystem == 'body':
            return 'B2', 'Body validation changes first gate the deterministic pilot band.'
        return 'B1', 'Shared governance changes must reopen the rollout from the first band.'
    return 'B1', 'Unknown change classes default to the safest re-entry point.'


def subsystem_names_for_class(subsystem: str) -> list[str]:
    return ['body', 'mouth', 'lighting'] if subsystem == 'shared' else [subsystem]


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: combined_engine_implementation_test_matrix_report.py <change-classes.json> <rollout-matrix.json> <research-root>')
        return 2

    change_classes = json.loads(Path(sys.argv[1]).read_text())
    matrix = json.loads(Path(sys.argv[2]).read_text())
    research_root = Path(sys.argv[3])
    outputs_root = research_root / 'engineer-handoff-packet' / 'outputs'

    bands = [band for band in matrix.get('bands', []) if band.get('id')]
    band_order = [band['id'] for band in bands]
    band_index = {band_id: idx for idx, band_id in enumerate(band_order)}

    test_matrix = []
    invalid: list[str] = []
    for change_class in change_classes.get('changeClasses', []):
        change_class_id = change_class.get('changeClassId')
        change_type = change_class.get('changeType', '')
        subsystem = change_class.get('subsystem', '')
        reentry_band, rationale = reentry_rule(change_type, subsystem)
        if reentry_band not in band_index:
            invalid.append(f'{change_class_id}:invalid-reentry-band:{reentry_band}')
            continue
        active_subsystems = subsystem_names_for_class(subsystem)
        for band in bands:
            band_id = band['id']
            reopened = band_index[band_id] >= band_index[reentry_band]
            validation_artifacts: list[str] = []
            if reopened:
                validation_artifacts.extend(GLOBAL_VALIDATION_ARTIFACTS)
                for subsystem_name in active_subsystems:
                    validation_artifacts.extend(band.get(subsystem_name, {}).get('requiredOutputs', []))
                validation_artifacts = sorted(dict.fromkeys(validation_artifacts))
            missing_artifacts = [artifact for artifact in validation_artifacts if not (outputs_root / artifact).exists()]
            test_matrix.append({
                'changeClassId': change_class_id,
                'bandId': band_id,
                'reentryBand': reentry_band,
                'reopened': reopened,
                'validationArtifacts': validation_artifacts,
                'missingArtifacts': missing_artifacts,
                'ready': reopened is False or not missing_artifacts,
                'rationale': rationale,
            })

    result = {
        'changeClassCount': len(change_classes.get('changeClasses', [])),
        'bandCount': len(bands),
        'globalValidationArtifacts': GLOBAL_VALIDATION_ARTIFACTS,
        'testMatrix': test_matrix,
        'valid': not invalid and all(row['ready'] for row in test_matrix),
    }
    if invalid:
        result['invalidClasses'] = invalid
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
