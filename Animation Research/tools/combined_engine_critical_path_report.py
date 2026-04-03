#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def build_graph(payload: dict) -> tuple[dict[str, list[str]], dict[str, list[str]], dict[str, int]]:
    packages = {item.get('workPackageId'): item for item in payload.get('workPackages', []) if item.get('workPackageId')}
    parents: dict[str, list[str]] = {pkg_id: [] for pkg_id in packages}
    children: dict[str, list[str]] = {pkg_id: [] for pkg_id in packages}
    indegree: dict[str, int] = {pkg_id: 0 for pkg_id in packages}
    for pkg_id, item in packages.items():
        for dep in item.get('dependsOn', []):
            if dep in packages:
                parents[pkg_id].append(dep)
                children[dep].append(pkg_id)
                indegree[pkg_id] += 1
    return parents, children, indegree


def longest_chain(packages_payload: dict) -> list[str]:
    packages = {item.get('workPackageId'): item for item in packages_payload.get('workPackages', []) if item.get('workPackageId')}
    parents, children, indegree = build_graph(packages_payload)
    queue = [pkg_id for pkg_id, degree in indegree.items() if degree == 0]
    distance = {pkg_id: 1 for pkg_id in queue}
    predecessor: dict[str, str | None] = {pkg_id: None for pkg_id in queue}

    while queue:
        current = queue.pop(0)
        for child in children[current]:
            cand = distance[current] + 1
            if cand > distance.get(child, 0):
                distance[child] = cand
                predecessor[child] = current
            indegree[child] -= 1
            if indegree[child] == 0:
                queue.append(child)

    if not distance:
        return []
    tail = max(distance, key=distance.get)
    chain = []
    while tail is not None:
        chain.append(tail)
        tail = predecessor.get(tail)
    return list(reversed(chain))


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: combined_engine_critical_path_report.py <work-packages.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    packages = {item.get('workPackageId'): item for item in payload.get('workPackages', []) if item.get('workPackageId')}
    parents, children, indegree = build_graph(payload)
    critical_path = longest_chain(payload)
    critical_set = set(critical_path)
    top_priority = critical_path[:3]

    frontier = critical_path[:1]
    available_parallel = sorted(
        pkg_id
        for pkg_id, degree in indegree.items()
        if degree == 0 and pkg_id not in critical_set
    )
    if not available_parallel and frontier:
        first = frontier[0]
        available_parallel = sorted(pkg_id for pkg_id in children.get(first, []) if pkg_id not in critical_set)

    result = {
        'criticalPathLength': len(critical_path),
        'criticalPath': critical_path,
        'topPriorityPackages': top_priority,
        'parallelReliefPackages': available_parallel,
        'valid': len(critical_path) > 0,
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
