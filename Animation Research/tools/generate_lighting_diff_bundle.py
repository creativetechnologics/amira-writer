#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

from lighting_fixture_diff_report import build_report


def to_markdown(report: dict) -> str:
    lines = ['# Lighting Fixture Diff Report', '']
    lines.append(f"Regression detected: {'yes' if report['hasRegression'] else 'no'}")
    lines.append('')
    lines.append('## summary')
    for key, value in report.get('summary', {}).items():
        lines.append(f'- {key}: {value}')
    lines.append('')
    lines.append('## regressions')
    if report['regressions']:
        for item in report['regressions']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    lines.append('## warnings')
    if report['warnings']:
        for item in report['warnings']:
            lines.append(f"- [{item['severity']}] {item['description']}")
    else:
        lines.append('- none')
    lines.append('')
    return '\n'.join(lines)


def main() -> int:
    if len(sys.argv) != 6:
        print('Usage: generate_lighting_diff_bundle.py <old-channels.json> <new-channels.json> <old-motion.json> <new-motion.json> <out-dir>')
        return 2
    old_channels = json.loads(Path(sys.argv[1]).read_text())
    new_channels = json.loads(Path(sys.argv[2]).read_text())
    old_motion = json.loads(Path(sys.argv[3]).read_text())
    new_motion = json.loads(Path(sys.argv[4]).read_text())
    out = Path(sys.argv[5])
    out.mkdir(parents=True, exist_ok=True)
    report = build_report(old_channels, new_channels, old_motion, new_motion)
    (out / 'lighting_fixture_diff_report.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'lighting_fixture_diff_report.md').write_text(to_markdown(report) + '\n')
    print(json.dumps({'outDir': str(out), 'hasRegression': report['hasRegression']}, indent=2))
    return 1 if report['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
