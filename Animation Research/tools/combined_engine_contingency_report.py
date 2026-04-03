#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def staffing_maps(staffing: dict) -> tuple[dict[str, str], dict[str, list[str]]]:
    owner_by_package: dict[str, str] = {}
    support_by_band: dict[str, list[str]] = {}
    for assignment in staffing.get('assignments', []):
        pkg_id = assignment.get('workPackageId')
        track_id = assignment.get('trackId')
        if pkg_id and track_id:
            owner_by_package[pkg_id] = track_id
    for assignment in staffing.get('supportAssignments', []):
        band_id = assignment.get('bandId')
        track_id = assignment.get('trackId')
        if band_id and track_id:
            support_by_band.setdefault(band_id, [])
            if track_id not in support_by_band[band_id]:
                support_by_band[band_id].append(track_id)
    return owner_by_package, support_by_band


def fallback_tracks(owner_track: str, support_tracks: list[str]) -> list[str]:
    ordered = []
    for track_id in support_tracks:
        if track_id != owner_track and track_id not in ordered:
            ordered.append(track_id)
    if 'validation-track' != owner_track and 'validation-track' not in ordered:
        ordered.append('validation-track')
    if 'fixture-track' != owner_track and 'fixture-track' not in ordered:
        ordered.append('fixture-track')
    return ordered


def track_action(track_id: str, band_id: str, responsibility: str) -> str:
    if track_id == 'adapter-track':
        return f'Keep compatibility adapters and schema guards moving inside {band_id} while the main {responsibility} blocker clears.'
    if track_id == 'runtime-track':
        return f'Advance deterministic harness work and non-blocking playback probes inside {band_id} without widening scope.'
    if track_id == 'validation-track':
        return f'Keep regression gates, audits, and acceptance checks warm for {band_id} so blocked work can re-enter quickly.'
    return f'Expand fixtures, examples, and handoff coverage for {band_id} so downstream teams stay unblocked.'


def main() -> int:
    if len(sys.argv) != 4:
        print('Usage: combined_engine_contingency_report.py <risk-report.json> <work-packages.json> <staffing-map.json>')
        return 2

    risk_payload = json.loads(Path(sys.argv[1]).read_text())
    work_payload = json.loads(Path(sys.argv[2]).read_text())
    staffing_payload = json.loads(Path(sys.argv[3]).read_text())

    packages = {item.get('workPackageId'): item for item in work_payload.get('workPackages', []) if item.get('workPackageId')}
    owner_by_package, support_by_band = staffing_maps(staffing_payload)
    invalid: list[str] = []

    risk_register = risk_payload.get('riskRegister', [])
    trigger_candidates = [item for item in risk_register if item.get('riskLevel') in {'critical', 'high'}]
    trigger_packages = []
    seen_bands: set[str] = set()
    for item in trigger_candidates:
        pkg_id = item.get('workPackageId')
        if pkg_id not in packages:
            invalid.append(f'unknown-work-package:{pkg_id}')
            continue
        band_id = item.get('bandId')
        owner_track = owner_by_package.get(pkg_id, item.get('ownerTrack', 'unassigned'))
        support_tracks = support_by_band.get(band_id, [])
        fallback = fallback_tracks(owner_track, support_tracks)
        keep_moving = list(item.get('contingencyWork', []))
        if not keep_moving:
            keep_moving = ['Keep validation and fixture maintenance moving while the blocker clears.']
        trigger_packages.append({
            'workPackageId': pkg_id,
            'bandId': band_id,
            'ownerTrack': owner_track,
            'riskLevel': item.get('riskLevel'),
            'fallbackTracks': fallback,
            'immediateActions': list(item.get('mitigationActions', []))[:4],
            'keepMovingWork': keep_moving,
            'exitCriteria': [
                f'{pkg_id} has a stable artifact path and updated validation output.',
                f'{band_id} downstream packages can resume without changing the shared contract.'
            ],
        })
        seen_bands.add(band_id)

    band_playbooks = []
    all_bands = []
    for item in work_payload.get('workPackages', []):
        band_id = item.get('bandId')
        if band_id and band_id not in all_bands:
            all_bands.append(band_id)
    for band_id in all_bands:
        band_packages = [item for item in trigger_packages if item.get('bandId') == band_id]
        support_tracks = support_by_band.get(band_id, [])
        band_playbooks.append({
            'bandId': band_id,
            'primaryBlockers': [item['workPackageId'] for item in band_packages] or [pkg.get('workPackageId') for pkg in work_payload.get('workPackages', []) if pkg.get('bandId') == band_id][:1],
            'adapterFallback': track_action('adapter-track', band_id, 'adapter'),
            'runtimeFallback': track_action('runtime-track', band_id, 'runtime'),
            'validationFallback': track_action('validation-track', band_id, 'validation'),
            'fixtureFallback': track_action('fixture-track', band_id, 'fixture'),
        })

    track_fallbacks = {}
    for track_id in {assignment.get('trackId') for assignment in staffing_payload.get('assignments', []) if assignment.get('trackId')} | {'fixture-track'}:
        if track_id == 'adapter-track':
            summary = 'Hold contract shape stable, narrow scope, and advance schema guards.'
        elif track_id == 'runtime-track':
            summary = 'Keep deterministic harnesses minimal and avoid branching into new scene classes while blocked.'
        elif track_id == 'validation-track':
            summary = 'Convert partial artifacts into continuously runnable gates so quality checks do not stall.'
        else:
            summary = 'Expand fixtures, examples, and handoff artifacts so restart cost stays low.'
        track_fallbacks[track_id] = summary

    global_contingencies = [
        'Protect the first adapter and runtime packages from side work while they remain on the critical path.',
        'Use validation-track and fixture-track as the default relief valves whenever a runtime or adapter package slips.',
        'Do not widen scope inside a blocked band; only advance already-declared fallback work.',
    ]

    result = {
        'triggerPackages': trigger_packages,
        'bandPlaybooks': band_playbooks,
        'trackFallbacks': track_fallbacks,
        'globalContingencies': global_contingencies,
        'valid': not invalid and bool(trigger_packages) and len(band_playbooks) == len(all_bands),
    }
    if invalid:
        result['invalid'] = invalid
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
