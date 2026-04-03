#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: hero_location_usage_report.py <usage-matrix.json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    totals: dict[str, int] = {}
    for character in payload.get('characters', []):
        for entry in character.get('locationUsage', []):
            location_id = entry.get('locationId')
            if location_id:
                totals[location_id] = totals.get(location_id, 0) + int(entry.get('weight', 0))
    ordered = sorted(totals.items(), key=lambda item: (-item[1], item[0]))
    result = {
        'locationTotals': [{"locationId": loc, "weight": weight} for loc, weight in ordered],
        'topLocations': [loc for loc, _ in ordered[:5]],
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
