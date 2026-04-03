#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_RESPONSIBILITIES = {'adapter', 'runtime', 'validation'}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: combined_engine_work_package_report.py <work-packages.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    packages = payload.get('workPackages', [])
    ids = {item.get('workPackageId') for item in packages if item.get('workPackageId')}
    invalid = []
    by_band: dict[str, int] = {}
    by_resp: dict[str, int] = {}
    by_subsystem: dict[str, int] = {}
    responsibilities_by_band: dict[str, set[str]] = {}

    for item in packages:
        pkg_id = item.get('workPackageId')
        band_id = item.get('bandId')
        responsibility = item.get('responsibility')
        subsystem = item.get('subsystem')
        if not pkg_id or not band_id or not responsibility or not subsystem:
            invalid.append(pkg_id or 'missing-work-package-fields')
            continue
        for dep in item.get('dependsOn', []):
            if dep not in ids:
                invalid.append(f'{pkg_id}:missing-dependency:{dep}')
        if not item.get('requiredArtifacts') or not item.get('deliverables'):
            invalid.append(f'{pkg_id}:missing-requirements')
        by_band[band_id] = by_band.get(band_id, 0) + 1
        by_resp[responsibility] = by_resp.get(responsibility, 0) + 1
        by_subsystem[subsystem] = by_subsystem.get(subsystem, 0) + 1
        responsibilities_by_band.setdefault(band_id, set()).add(responsibility)

    for band_id, responsibilities in responsibilities_by_band.items():
        missing = REQUIRED_RESPONSIBILITIES - responsibilities
        if missing:
            invalid.append(f'{band_id}:missing-responsibilities:{",".join(sorted(missing))}')

    result = {
        'workPackageCount': len(packages),
        'bandCount': len(by_band),
        'packagesByBand': by_band,
        'packagesByResponsibility': by_resp,
        'packagesBySubsystem': by_subsystem,
        'invalidPackages': invalid,
        'valid': not invalid,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
