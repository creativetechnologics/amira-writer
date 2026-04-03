#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

SEVERITY_WEIGHT = {'critical': 4, 'major': 2, 'minor': 1, 'info': 0}


def decide(payload: dict) -> str:
    decision = payload.get('overall_decision')
    if decision:
        return decision
    weight = sum(SEVERITY_WEIGHT.get(item.get('severity'), 0) for item in payload.get('issues', []))
    if weight >= 6:
        return 'regenerate'
    if weight >= 2:
        return 'edit'
    return 'approve'


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: asset_review_decision.py <asset-review-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    print(decide(payload))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
