#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from collections import deque
from pathlib import Path

SEVERITY_SCORE = {"critical": 3, "high": 2, "medium": 1, "low": 0}


def build_graph(payload: dict) -> tuple[dict[str, dict], dict[str, list[str]], dict[str, list[str]], dict[str, int], list[str]]:
    packages = {item.get('workPackageId'): item for item in payload.get('workPackages', []) if item.get('workPackageId')}
    parents: dict[str, list[str]] = {pkg_id: [] for pkg_id in packages}
    children: dict[str, list[str]] = {pkg_id: [] for pkg_id in packages}
    indegree: dict[str, int] = {pkg_id: 0 for pkg_id in packages}
    invalid: list[str] = []

    for pkg_id, item in packages.items():
        for dep in item.get('dependsOn', []):
            if dep not in packages:
                invalid.append(f'{pkg_id}:missing-dependency:{dep}')
                continue
            parents[pkg_id].append(dep)
            children[dep].append(pkg_id)
            indegree[pkg_id] += 1
    return packages, parents, children, indegree, invalid


def longest_chain(payload: dict) -> list[str]:
    packages, parents, children, indegree, _ = build_graph(payload)
    queue = deque([pkg_id for pkg_id, degree in indegree.items() if degree == 0])
    distance = {pkg_id: 1 for pkg_id in queue}
    predecessor: dict[str, str | None] = {pkg_id: None for pkg_id in queue}
    indegree_work = indegree.copy()

    while queue:
        current = queue.popleft()
        for child in children[current]:
            cand = distance[current] + 1
            if cand > distance.get(child, 0):
                distance[child] = cand
                predecessor[child] = current
            indegree_work[child] -= 1
            if indegree_work[child] == 0:
                queue.append(child)

    if not distance:
        return []
    tail = max(distance, key=distance.get)
    chain = []
    while tail is not None:
        chain.append(tail)
        tail = predecessor.get(tail)
    return list(reversed(chain))


def descendants(children: dict[str, list[str]], pkg_id: str) -> set[str]:
    seen: set[str] = set()
    queue = deque(children.get(pkg_id, []))
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        queue.extend(children.get(current, []))
    return seen


def owner_tracks(staffing: dict) -> tuple[dict[str, str], dict[str, list[str]]]:
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


def risk_type(item: dict, index: int, total: int) -> str:
    responsibility = item.get('responsibility')
    band_id = item.get('bandId')
    if index == 0:
        return 'foundation-chokepoint'
    if band_id == 'B6':
        return 'late-governance-lock'
    if responsibility == 'adapter':
        return 'contract-chokepoint'
    if responsibility == 'runtime':
        return 'runtime-serial-blocker'
    return 'validation-gate'


def risk_level(index: int, total: int, downstream_count: int, responsibility: str) -> str:
    if index == 0 or downstream_count >= max(8, total - 3):
        return 'critical'
    if responsibility == 'runtime' and downstream_count >= max(6, total // 2):
        return 'critical'
    if index <= max(2, total // 4) or downstream_count >= max(4, total // 3):
        return 'high'
    if responsibility == 'validation' and index >= total - 2:
        return 'medium'
    return 'medium'


def mitigation_actions(item: dict, owner_track: str, same_band_support: list[str]) -> list[str]:
    responsibility = item.get('responsibility')
    band_id = item.get('bandId')
    actions: list[str] = []
    if responsibility == 'adapter':
        actions.extend([
            'Freeze the adapter contract early and keep a minimal compatibility shim available.',
            'Promote schema and fixture checks before runtime wiring expands.'
        ])
    elif responsibility == 'runtime':
        actions.extend([
            'Limit scope to the smallest deterministic harness that proves the band objective.',
            'Keep fallback stubs for non-critical subsystems so downstream validation can start sooner.'
        ])
    else:
        actions.extend([
            'Run validation gates on partial artifacts early instead of waiting for full rollout completion.',
            'Automate regression outputs so governance checks do not become manual blockers.'
        ])
    if owner_track:
        actions.append(f'Protect focus time for {owner_track} while this package is active.')
    if same_band_support:
        actions.append(f'Use support tracks in {band_id} for fixture and audit maintenance: {", ".join(sorted(same_band_support))}.')
    return actions


def contingency_work(item: dict, same_band_noncritical: list[str], global_parallel_relief: list[str]) -> list[str]:
    work: list[str] = []
    if same_band_noncritical:
        work.append(f'Advance same-band support work: {", ".join(sorted(same_band_noncritical))}.')
    if global_parallel_relief:
        work.append(f'Keep global parallel-relief packages moving: {", ".join(sorted(global_parallel_relief))}.')
    responsibility = item.get('responsibility')
    if responsibility != 'validation':
        work.append('Expand fixture coverage and diff outputs so downstream validation can start immediately once the blocker clears.')
    else:
        work.append('Harden policy, documentation, and audit expectations while runtime work continues in parallel.')
    return work


def main() -> int:
    if len(sys.argv) != 3:
        print('Usage: combined_engine_risk_report.py <work-packages.json> <staffing-map.json>')
        return 2

    work_payload = json.loads(Path(sys.argv[1]).read_text())
    staffing_payload = json.loads(Path(sys.argv[2]).read_text())

    packages, parents, children, indegree, invalid = build_graph(work_payload)
    critical_path = longest_chain(work_payload)
    critical_set = set(critical_path)
    owner_by_package, support_by_band = owner_tracks(staffing_payload)

    root_packages = sorted([pkg_id for pkg_id, degree in indegree.items() if degree == 0])
    parallel_relief_packages = sorted([pkg_id for pkg_id in root_packages if pkg_id not in critical_set])
    if not parallel_relief_packages and critical_path:
        first = critical_path[0]
        parallel_relief_packages = sorted([pkg_id for pkg_id in children.get(first, []) if pkg_id not in critical_set])

    critical_track_counts: dict[str, int] = {}
    risk_register: list[dict] = []
    for index, pkg_id in enumerate(critical_path):
        item = packages[pkg_id]
        owner_track = owner_by_package.get(pkg_id, 'unassigned')
        critical_track_counts[owner_track] = critical_track_counts.get(owner_track, 0) + 1
        downstream = descendants(children, pkg_id)
        band_id = item.get('bandId')
        same_band_noncritical = [
            other_id for other_id, other in packages.items()
            if other.get('bandId') == band_id and other_id not in critical_set and other_id != pkg_id
        ]
        level = risk_level(index, len(critical_path), len(downstream), item.get('responsibility', ''))
        summary = (
            f'{pkg_id} sits at critical-path position {index + 1} with '
            f'{len(downstream)} downstream packages relying on it.'
        )
        risk_register.append({
            'riskId': f'risk-{pkg_id}',
            'workPackageId': pkg_id,
            'bandId': band_id,
            'responsibility': item.get('responsibility'),
            'ownerTrack': owner_track,
            'criticalPathIndex': index + 1,
            'downstreamPackageCount': len(downstream),
            'riskLevel': level,
            'riskType': risk_type(item, index, len(critical_path)),
            'summary': summary,
            'mitigationActions': mitigation_actions(item, owner_track, support_by_band.get(band_id, [])),
            'contingencyWork': contingency_work(item, same_band_noncritical, parallel_relief_packages),
        })

    track_concentration = {
        track_id: {
            'criticalPathPackageCount': count,
            'criticalPathShare': round(count / len(critical_path), 3) if critical_path else 0.0,
        }
        for track_id, count in sorted(critical_track_counts.items())
    }

    program_risks: list[dict] = []
    if len(root_packages) == 1:
        program_risks.append({
            'riskId': 'program-single-root',
            'riskLevel': 'high',
            'summary': f'The rollout graph has a single root package: {root_packages[0]}.',
            'trigger': 'Any slip in the first adapter package delays the entire program.',
            'mitigationActions': [
                'Keep the initial adapter contract intentionally narrow.',
                'Pre-stage validation and fixture maintenance work so the first band gets fast feedback.'
            ],
        })
    if len(critical_path) >= 12:
        program_risks.append({
            'riskId': 'program-long-serial-chain',
            'riskLevel': 'critical',
            'summary': f'The combined engine currently has a long serial chain of {len(critical_path)} packages.',
            'trigger': 'Small slips compound because downstream bands start only after prior chain segments clear.',
            'mitigationActions': [
                'Preserve early parallel-relief work so validation and fixture tracks stay productive.',
                'Keep each band scoped to the minimum proof needed for the next band.'
            ],
        })
    for track_id, details in track_concentration.items():
        if details['criticalPathShare'] >= 0.4:
            program_risks.append({
                'riskId': f'program-track-concentration-{track_id}',
                'riskLevel': 'high',
                'summary': f'{track_id} owns {details["criticalPathPackageCount"]} critical-path packages ({details["criticalPathShare"]:.0%} share).',
                'trigger': 'That track becomes the schedule choke point if staffing or focus narrows.',
                'mitigationActions': [
                    'Avoid assigning side work to the concentrated track during critical-path execution.',
                    'Use fixture and validation work to keep non-concentrated tracks moving in parallel.'
                ],
            })
    if len(parallel_relief_packages) <= 1:
        program_risks.append({
            'riskId': 'program-weak-parallel-relief',
            'riskLevel': 'medium',
            'summary': 'There are too few clearly parallel relief packages early in the program.',
            'trigger': 'Teams may idle while waiting for the critical-path chain to unblock.',
            'mitigationActions': [
                'Pre-assign fixture, audit, and documentation upkeep as contingency work.',
                'Convert any non-blocking validation package into a continuously runnable gate.'
            ],
        })

    ranked_risks = sorted(
        risk_register,
        key=lambda item: (-SEVERITY_SCORE[item['riskLevel']], item['criticalPathIndex'], -item['downstreamPackageCount'])
    )

    result = {
        'criticalPathLength': len(critical_path),
        'parallelReliefPackages': parallel_relief_packages,
        'trackConcentration': track_concentration,
        'programRisks': program_risks,
        'riskRegister': ranked_risks,
        'highestRiskPackages': [item['workPackageId'] for item in ranked_risks[:3]],
        'valid': not invalid and bool(critical_path),
    }
    if invalid:
        result['invalidPackages'] = invalid
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
