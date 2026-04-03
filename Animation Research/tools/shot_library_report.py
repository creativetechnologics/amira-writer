#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: shot_library_report.py <shot-library-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    shots = payload.get('shots', [])
    print(json.dumps({
        'count': len(shots),
        'categories': sorted({shot.get('category') for shot in shots}),
        'defaultRoutingCounts': {
            mode: sum(1 for shot in shots if shot.get('defaultRouting') == mode)
            for mode in ['internal', 'hybrid', 'ai-video-fallback']
        }
    }, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
