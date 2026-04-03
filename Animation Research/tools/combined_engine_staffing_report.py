#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_PRIMARY_TRACKS = {
    'adapter-track': 'adapter',
    'runtime-track': 'runtime',
    'validation-track': 'validation',
}


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: combined_engine_staffing_report.py <staffing-map.json> <work-packages.json>')
        return 2

    staffing = json.loads(Path(sys.argv[1]).read_text())
    work_packages_payload = json.loads(Path(sys.argv[2]).read_text())

    tracks = {item.get('trackId'): item for item in staffing.get('tracks', []) if item.get('trackId')}
    work_packages = {item.get('workPackageId'): item for item in work_packages_payload.get('workPackages', []) if item.get('workPackageId')}

    invalid = []
    packages_by_track: dict[str, int] = {}
    bands_by_track: dict[str, set[str]] = {track_id: set() for track_id in tracks}
    primary_assignment_count: dict[str, int] = {pkg_id: 0 for pkg_id in work_packages}

    for assignment in staffing.get('assignments', []):
        pkg_id = assignment.get('workPackageId')
        track_id = assignment.get('trackId')
        if pkg_id not in work_packages:
            invalid.append(f'unknown-work-package:{pkg_id}')
            continue
        if track_id not in tracks:
            invalid.append(f'unknown-track:{track_id}')
            continue
        primary_assignment_count[pkg_id] += 1
        packages_by_track[track_id] = packages_by_track.get(track_id, 0) + 1
        bands_by_track.setdefault(track_id, set()).add(work_packages[pkg_id].get('bandId'))

    for assignment in staffing.get('supportAssignments', []):
        band_id = assignment.get('bandId')
        track_id = assignment.get('trackId')
        if track_id not in tracks:
            invalid.append(f'unknown-track:{track_id}')
            continue
        if not band_id:
            invalid.append('support-assignment-missing-band')
            continue
        bands_by_track.setdefault(track_id, set()).add(band_id)

    for pkg_id, count in primary_assignment_count.items():
        if count != 1:
            invalid.append(f'{pkg_id}:primary-assignment-count:{count}')

    responsibilities_by_band: dict[str, set[str]] = {}
    for assignment in staffing.get('assignments', []):
        pkg_id = assignment.get('workPackageId')
        track_id = assignment.get('trackId')
        package = work_packages.get(pkg_id)
        if not package:
            continue
        band_id = package.get('bandId')
        track_kind = REQUIRED_PRIMARY_TRACKS.get(track_id)
        if track_kind:
            responsibilities_by_band.setdefault(band_id, set()).add(track_kind)

    for band_id, present in responsibilities_by_band.items():
        missing = set(REQUIRED_PRIMARY_TRACKS.values()) - present
        if missing:
            invalid.append(f'{band_id}:missing-primary-tracks:{",".join(sorted(missing))}')

    result = {
        'workPackageCount': len(work_packages),
        'tracks': sorted(tracks.keys()),
        'packagesByTrack': packages_by_track,
        'bandsCoveredByTrack': {track_id: sorted(values) for track_id, values in bands_by_track.items()},
        'invalidAssignments': invalid,
        'valid': not invalid,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
