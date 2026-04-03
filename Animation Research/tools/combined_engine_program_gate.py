#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def file_exists(path: Path) -> bool:
    return path.exists()


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: combined_engine_program_gate.py <rollout-matrix.json> <research-root>')
        return 2

    matrix_path = Path(sys.argv[1])
    research_root = Path(sys.argv[2])
    outputs_root = research_root / 'engineer-handoff-packet' / 'outputs'
    examples_root = research_root / 'examples'

    payload = json.loads(matrix_path.read_text())
    bands = payload.get('bands', [])
    statuses = []
    ready_bands = []
    blocked_bands = []
    ready_lookup: dict[str, bool] = {}

    for band in bands:
        band_id = band.get('id', 'unknown')
        deps = band.get('dependsOn', [])
        dependency_ready = all(ready_lookup.get(dep, False) for dep in deps)
        missing_docs = []
        missing_fixtures = []
        missing_outputs = []

        for subsystem in ('body', 'mouth', 'lighting'):
            entry = band.get(subsystem, {})
            for doc in entry.get('requiredDocs', []):
                if not file_exists(research_root / doc):
                    missing_docs.append(doc)
            for fixture in entry.get('requiredFixtures', []):
                if not file_exists(examples_root / fixture):
                    missing_fixtures.append(fixture)
            for output in entry.get('requiredOutputs', []):
                if not file_exists(outputs_root / output):
                    missing_outputs.append(output)

        ready = dependency_ready and not missing_docs and not missing_fixtures and not missing_outputs
        ready_lookup[band_id] = ready
        if ready:
            ready_bands.append(band_id)
        else:
            blocked_bands.append(band_id)

        statuses.append({
            'bandId': band_id,
            'ready': ready,
            'dependencyReady': dependency_ready,
            'missingDocs': sorted(set(missing_docs)),
            'missingFixtures': sorted(set(missing_fixtures)),
            'missingOutputs': sorted(set(missing_outputs)),
        })

    highest = None
    for status in statuses:
        if status['ready']:
            highest = status['bandId']
        else:
            break

    result = {
        'bandCount': len(bands),
        'readyBands': ready_bands,
        'blockedBands': blocked_bands,
        'highestContiguousReadyBand': highest,
        'bandStatuses': statuses,
        'valid': True,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
