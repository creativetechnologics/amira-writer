#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: acceptance_matrix_check.py <matrix.json>')
        return 2

    matrix = json.loads(Path(sys.argv[1]).read_text())
    phases = matrix.get('phases', [])
    failing = []
    total = 0
    passed = 0

    for phase in phases:
        for criterion in phase.get('criteria', []):
            total += 1
            if criterion.get('status') == 'pass':
                passed += 1
            else:
                failing.append({
                    'phase': phase.get('name', 'unknown'),
                    'criterion': criterion.get('id', 'unknown'),
                    'status': criterion.get('status', 'missing'),
                })

    result = {
        'phaseCount': len(phases),
        'criterionCount': total,
        'passedCount': passed,
        'failingCount': len(failing),
        'ready': len(failing) == 0,
        'failing': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['ready'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
