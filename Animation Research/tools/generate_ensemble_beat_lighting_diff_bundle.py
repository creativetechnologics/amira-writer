#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

from ensemble_beat_lighting_diff_report import report


def to_markdown(payload: dict) -> str:
    lines = ['# Ensemble Beat Lighting Diff Report', '']
    lines.append(f"Regression detected: {'yes' if payload['hasRegression'] else 'no'}")
    lines.append('')
    lines.append('## summary')
    for key, value in payload.get('summary', {}).items():
        lines.append(f'- {key}: {value}')
    lines.append('')
    lines.append('## regressions')
    if payload.get('regressions'):
        for item in payload['regressions']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    lines.append('## warnings')
    if payload.get('warnings'):
        for item in payload['warnings']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    return '\n'.join(lines) + '\n'


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: generate_ensemble_beat_lighting_diff_bundle.py <old.json> <new.json> <out-dir>')
        return 2
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    payload = report(json.loads(Path(sys.argv[1]).read_text()), json.loads(Path(sys.argv[2]).read_text()))
    (out / 'ensemble_beat_lighting_diff_report.json').write_text(json.dumps(payload, indent=2) + '\n')
    (out / 'ensemble_beat_lighting_diff_report.md').write_text(to_markdown(payload))
    print(json.dumps({'outDir': str(out), 'hasRegression': payload['hasRegression']}, indent=2))
    return 1 if payload['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
