#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def exists(path: Path) -> bool:
    return path.exists()


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: combined_engine_band_exit_gate.py <rollout-matrix.json> <research-root>')
        return 2

    matrix = json.loads(Path(sys.argv[1]).read_text())
    research_root = Path(sys.argv[2])
    outputs_root = research_root / 'engineer-handoff-packet' / 'outputs'
    examples_root = research_root / 'examples'

    exit_ready_lookup: dict[str, bool] = {}
    band_statuses = []
    exit_ready_bands = []
    blocked_bands = []

    for band in matrix.get('bands', []):
        band_id = band.get('id', 'unknown')
        band_name = band.get('name', '')
        deps = band.get('dependsOn', [])
        dependency_ready = all(exit_ready_lookup.get(dep, False) for dep in deps)
        missing_docs: list[str] = []
        missing_fixtures: list[str] = []
        missing_outputs: list[str] = []
        subsystem_checks = {}
        exit_criteria = []

        for subsystem in ('body', 'mouth', 'lighting'):
            entry = band.get(subsystem, {})
            subsystem_missing_docs = [doc for doc in entry.get('requiredDocs', []) if not exists(research_root / doc)]
            subsystem_missing_fixtures = [fixture for fixture in entry.get('requiredFixtures', []) if not exists(examples_root / fixture)]
            subsystem_missing_outputs = [output for output in entry.get('requiredOutputs', []) if not exists(outputs_root / output)]
            missing_docs.extend(subsystem_missing_docs)
            missing_fixtures.extend(subsystem_missing_fixtures)
            missing_outputs.extend(subsystem_missing_outputs)
            subsystem_ready = not subsystem_missing_docs and not subsystem_missing_fixtures and not subsystem_missing_outputs
            subsystem_checks[subsystem] = {
                'ready': subsystem_ready,
                'missingDocs': subsystem_missing_docs,
                'missingFixtures': subsystem_missing_fixtures,
                'missingOutputs': subsystem_missing_outputs,
            }
            exit_criteria.append(
                f'{subsystem} requires {len(entry.get("requiredDocs", []))} docs, '
                f'{len(entry.get("requiredFixtures", []))} fixtures, and {len(entry.get("requiredOutputs", []))} outputs.'
            )

        exit_ready = dependency_ready and not missing_docs and not missing_fixtures and not missing_outputs
        exit_ready_lookup[band_id] = exit_ready
        if exit_ready:
            exit_ready_bands.append(band_id)
        else:
            blocked_bands.append(band_id)

        band_statuses.append({
            'bandId': band_id,
            'bandName': band_name,
            'dependencyReady': dependency_ready,
            'missingDocs': sorted(set(missing_docs)),
            'missingFixtures': sorted(set(missing_fixtures)),
            'missingOutputs': sorted(set(missing_outputs)),
            'subsystemChecks': subsystem_checks,
            'exitCriteria': exit_criteria,
            'exitReady': exit_ready,
        })

    highest = None
    for status in band_statuses:
        if status['exitReady']:
            highest = status['bandId']
        else:
            break

    result = {
        'bandCount': len(band_statuses),
        'exitReadyBands': exit_ready_bands,
        'blockedBands': blocked_bands,
        'highestExitReadyBand': highest,
        'bandStatuses': band_statuses,
        'valid': True,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
