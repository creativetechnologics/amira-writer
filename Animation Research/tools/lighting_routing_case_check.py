#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_routing_case_check.py <cases.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    cases = payload.get('cases', [])
    failing = []
    for case in cases:
        if not case.get('lightingProfile') or not case.get('expectedRouting'):
            failing.append(case.get('id', 'unknown'))
    result = {
        'caseCount': len(cases),
        'valid': len(failing) == 0,
        'failingCases': failing,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
