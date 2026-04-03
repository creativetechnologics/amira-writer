#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: lighting_review_gate.py <review.json>')
        return 2
    review = json.loads(Path(sys.argv[1]).read_text())
    ok = (
        review.get('readability') in {'good', 'excellent'}
        and review.get('skinTonePreserved') is True
        and review.get('backgroundMatch') is True
        and review.get('lineIntegrity') in {'good', 'excellent'}
        and review.get('requiresRegeneration') is False
    )
    result = {
        'approved': ok,
        'requiresRegeneration': review.get('requiresRegeneration', False),
        'suggestedCorrections': review.get('suggestedCorrections', []),
    }
    print(json.dumps(result, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
