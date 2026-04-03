#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json

READINESS_SCORE = {
    'draft': 0,
    'blocking-ready': 1,
    'dialogue-ready': 2,
    'performance-ready': 3,
    'production-ready': 4,
}


def decide(readiness: str, complexity: int, revision_sensitivity: int) -> str:
    r = READINESS_SCORE[readiness]
    if r <= 0:
        return 'manual'
    if r == 1:
        return 'internal' if complexity <= 2 else 'hybrid'
    if r == 2:
        if complexity <= 4:
            return 'internal'
        if complexity <= 8:
            return 'hybrid'
        return 'ai-video-fallback'
    if r >= 3:
        if complexity <= 6 or revision_sensitivity >= 8:
            return 'internal'
        if complexity <= 9:
            return 'hybrid'
        return 'ai-video-fallback'
    return 'hybrid'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--readiness', choices=sorted(READINESS_SCORE), required=True)
    parser.add_argument('--complexity', type=int, required=True)
    parser.add_argument('--revision-sensitivity', type=int, required=True)
    args = parser.parse_args()
    print(json.dumps({'mode': decide(args.readiness, args.complexity, args.revision_sensitivity)}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
