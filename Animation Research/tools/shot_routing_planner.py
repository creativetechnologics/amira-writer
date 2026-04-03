#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json


def decide(package_readiness: float, camera: int, action: int, fx: int, revision: int) -> str:
    complexity = camera + action + fx
    if package_readiness >= 0.8 and complexity <= 5 and revision >= 7:
        return 'internal'
    if package_readiness >= 0.6 and complexity <= 8:
        return 'hybrid'
    return 'ai-video-fallback'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--package-readiness', type=float, required=True)
    parser.add_argument('--camera', type=int, required=True)
    parser.add_argument('--action', type=int, required=True)
    parser.add_argument('--fx', type=int, required=True)
    parser.add_argument('--revision', type=int, required=True)
    args = parser.parse_args()
    mode = decide(args.package_readiness, args.camera, args.action, args.fx, args.revision)
    print(json.dumps({'mode': mode}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
