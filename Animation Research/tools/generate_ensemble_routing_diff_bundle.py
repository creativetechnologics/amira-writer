#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

from ensemble_routing_diff_report import build_report


def to_markdown(report: dict) -> str:
    lines = ['# Ensemble Routing Diff Report', '']
    lines.append(f"Regression detected: {'yes' if report['hasRegression'] else 'no'}")
    lines.append('')
    lines.append('## summary')
    for key, value in report.get('summary', {}).items():
        lines.append(f'- {key}: {value}')
    lines.append('')
    lines.append('## regressions')
    if report.get('regressions'):
        for item in report['regressions']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    lines.append('## warnings')
    if report.get('warnings'):
        for item in report['warnings']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    return '\n'.join(lines)


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: generate_ensemble_routing_diff_bundle.py <old.json> <new.json> <out-dir>')
        return 2
    old_payload = json.loads(Path(sys.argv[1]).read_text())
    new_payload = json.loads(Path(sys.argv[2]).read_text())
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)
    report = build_report(old_payload, new_payload)
    (out_dir / 'ensemble_routing_diff_report.json').write_text(json.dumps(report, indent=2) + '\n')
    (out_dir / 'ensemble_routing_diff_report.md').write_text(to_markdown(report) + '\n')
    print(json.dumps({'outDir': str(out_dir), 'hasRegression': report['hasRegression']}, indent=2))
    return 1 if report['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
