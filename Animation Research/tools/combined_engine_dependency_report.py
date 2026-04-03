#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from collections import deque
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: combined_engine_dependency_report.py <work-packages.json>')
        return 2

    payload = json.loads(Path(sys.argv[1]).read_text())
    packages = payload.get('workPackages', [])
    pkg_map = {item.get('workPackageId'): item for item in packages if item.get('workPackageId')}
    invalid: list[str] = []
    indegree = {pkg_id: 0 for pkg_id in pkg_map}
    children: dict[str, list[str]] = {pkg_id: [] for pkg_id in pkg_map}

    for pkg_id, item in pkg_map.items():
        for dep in item.get('dependsOn', []):
            if dep not in pkg_map:
                invalid.append(f'{pkg_id}:missing-dependency:{dep}')
                continue
            indegree[pkg_id] += 1
            children[dep].append(pkg_id)

    root_packages = sorted([pkg_id for pkg_id, degree in indegree.items() if degree == 0])

    queue = deque(root_packages)
    indegree_work = indegree.copy()
    topo: list[str] = []
    layer_map: dict[str, int] = {}

    for pkg_id in root_packages:
        layer_map[pkg_id] = 0

    while queue:
        pkg_id = queue.popleft()
        topo.append(pkg_id)
        for child in children[pkg_id]:
            indegree_work[child] -= 1
            layer_map[child] = max(layer_map.get(child, 0), layer_map[pkg_id] + 1)
            if indegree_work[child] == 0:
                queue.append(child)

    has_cycle = len(topo) != len(pkg_map)
    if has_cycle:
        invalid.append('graph-cycle-detected')

    leaf_packages = sorted([pkg_id for pkg_id, deps in children.items() if not deps])
    parallel_layers: dict[int, list[str]] = {}
    for pkg_id, layer in layer_map.items():
        parallel_layers.setdefault(layer, []).append(pkg_id)
    parallel_ready_layers = {f'layer_{layer}': sorted(nodes) for layer, nodes in sorted(parallel_layers.items())}

    longest_chain = max(layer_map.values(), default=0) + 1 if layer_map else 0

    result = {
        'workPackageCount': len(pkg_map),
        'rootPackages': root_packages,
        'leafPackages': leaf_packages,
        'parallelReadyLayers': parallel_ready_layers,
        'longestDependencyChain': longest_chain,
        'invalidPackages': invalid,
        'hasCycle': has_cycle,
        'valid': not invalid and not has_cycle and bool(root_packages),
    }
    print(json.dumps(result, indent=2))
    return 0 if result['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
