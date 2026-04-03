#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ALLOWED = {'internal', 'hybrid', 'ai-video-fallback'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: shot_case_expectation_check.py <shot-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    shots = payload.get('shots', [])
    problems = [shot.get('shotId', 'unknown') for shot in shots if shot.get('defaultRouting') not in ALLOWED]
    print(json.dumps({'valid': not problems, 'problems': problems, 'count': len(shots)}, indent=2))
    return 0 if not problems else 1


if __name__ == '__main__':
    raise SystemExit(main())
