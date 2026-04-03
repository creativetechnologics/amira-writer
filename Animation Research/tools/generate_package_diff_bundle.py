#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def ids(items: list[dict], key: str = 'id') -> set[str]:
    return {item.get(key) for item in items if item.get(key)}


def build_report(old: dict, new: dict) -> dict:
    old_mouth = ids(old.get('mouthProfiles', []))
    new_mouth = ids(new.get('mouthProfiles', []))
    old_motion = ids(old.get('motionPrimitives', []))
    new_motion = ids(new.get('motionPrimitives', []))
    old_costumes = ids(old.get('costumePacks', []))
    new_costumes = ids(new.get('costumePacks', []))
    regressions = []
    if len(new_mouth) < len(old_mouth):
        regressions.append('mouth profile coverage dropped')
    if len(new_motion) < len(old_motion):
        regressions.append('motion primitive coverage dropped')
    if len(new_costumes) < len(old_costumes):
        regressions.append('costume pack coverage dropped')
    return {
        'removedMouthProfiles': sorted(old_mouth - new_mouth),
        'removedMotionPrimitives': sorted(old_motion - new_motion),
        'removedCostumePacks': sorted(old_costumes - new_costumes),
        'regressions': regressions,
        'hasRegression': bool(regressions),
    }


def to_markdown(report: dict) -> str:
    lines = ['# Package Diff Report', '']
    lines.append(f"Regression detected: {'yes' if report['hasRegression'] else 'no'}")
    lines.append('')
    for key in ['removedMouthProfiles', 'removedMotionPrimitives', 'removedCostumePacks']:
        lines.append(f'## {key}')
        values = report.get(key, [])
        if values:
            lines.extend(f'- {v}' for v in values)
        else:
            lines.append('- none')
        lines.append('')
    lines.append('## regressions')
    if report['regressions']:
        lines.extend(f'- {v}' for v in report['regressions'])
    else:
        lines.append('- none')
    return '\n'.join(lines) + '\n'


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: generate_package_diff_bundle.py <old> <new> <out-dir>')
        return 2
    old = json.loads(Path(sys.argv[1]).read_text())
    new = json.loads(Path(sys.argv[2]).read_text())
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    report = build_report(old, new)
    (out / 'package_diff_report.json').write_text(json.dumps(report, indent=2) + '\n')
    (out / 'package_diff_report.md').write_text(to_markdown(report))
    print(json.dumps({'outDir': str(out), 'hasRegression': report['hasRegression']}, indent=2))
    return 1 if report['hasRegression'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
