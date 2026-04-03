#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: promotion_gate_check.py <asset-review-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    decision = payload.get('overall_decision')
    confidence = float(payload.get('overall_confidence', 0))
    critical = any(issue.get('severity') == 'critical' for issue in payload.get('issues', []))
    major = any(issue.get('severity') == 'major' for issue in payload.get('issues', []))
    result = {
        'eligibleForPromotion': bool(decision == 'approve' and confidence >= 0.9 and not critical and not major),
        'reason': 'approved-high-confidence-clean' if (decision == 'approve' and confidence >= 0.9 and not critical and not major) else 'not-ready-for-promotion'
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
