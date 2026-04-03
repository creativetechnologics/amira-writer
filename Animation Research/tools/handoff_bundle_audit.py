#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_DOCS = {'README.md', 'adapter-task-checklist.md', 'pilot-brief.md', 'schema-upgrade-strategy.md', 'fixture-map.md'}
REQUIRED_FIXTURES = {'sample_hero_ready_package.json', 'sample_pilot_packet.json', 'sample_mouth_profile.json', 'sample_walk_and_sing_motion_plan.json', 'sample_asset_review.json'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: handoff_bundle_audit.py <handoff-dir>')
        return 2
    base = Path(sys.argv[1])
    docs = {p.name for p in (base / 'docs').glob('*') if p.is_file()}
    fixtures = {p.name for p in (base / 'fixtures').glob('*') if p.is_file()}
    payload = {
        'missingDocs': sorted(REQUIRED_DOCS - docs),
        'missingFixtures': sorted(REQUIRED_FIXTURES - fixtures),
    }
    payload['valid'] = not payload['missingDocs'] and not payload['missingFixtures']
    print(json.dumps(payload, indent=2))
    return 0 if payload['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
