#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: str) -> dict:
    return json.loads(Path(path).read_text())


def orchestrate(payload: dict) -> dict:
    decision = payload.get('overall_decision', 'escalate')
    rec = payload.get('edit_recommendation', {})
    next_action = payload.get('next_action')
    result = {
        'decision': decision,
        'next_action': next_action or decision,
        'should_review_again': decision in {'edit', 'regenerate'},
        'edit_prompt': rec.get('edit_prompt') if rec.get('use_edit') else None,
        'preserve_facts': rec.get('preserve_facts', []),
        'change_facts': rec.get('change_facts', []),
    }
    if decision == 'approve':
        result['promotion'] = 'approve_and_store'
    elif decision == 'edit':
        result['promotion'] = 'edit_then_recheck'
    elif decision == 'regenerate':
        result['promotion'] = 'regenerate_then_recheck'
    else:
        result['promotion'] = 'human_review'
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: correction_orchestrator.py <asset-review-json>')
        return 2
    payload = load(sys.argv[1])
    print(json.dumps(orchestrate(payload), indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
