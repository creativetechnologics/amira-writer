#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass

PRICE_2K_STANDARD = 0.101
PRICE_2K_BATCH = 0.050

@dataclass(frozen=True)
class CharacterPlan:
    name: str
    tier: str
    base_min: int
    base_max: int
    extra_costume_min: int
    extra_costume_max: int

PLANS = {
    'luke': CharacterPlan('Luke Hart', 'hero', 110, 140, 20, 28),
    'amira': CharacterPlan('Amira Nazari', 'hero', 105, 135, 18, 26),
    'yasmin': CharacterPlan('Yasmin Nazari', 'supporting', 55, 80, 10, 16),
}


def money(v: float) -> str:
    return f'${v:,.2f}'


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('character', choices=sorted(PLANS))
    parser.add_argument('--extra-costumes', type=int, default=0)
    args = parser.parse_args()
    plan = PLANS[args.character]
    total_min = plan.base_min + args.extra_costumes * plan.extra_costume_min
    total_max = plan.base_max + args.extra_costumes * plan.extra_costume_max
    payload = {
        'name': plan.name,
        'tier': plan.tier,
        'totalAssetsMin': total_min,
        'totalAssetsMax': total_max,
        'standard2KCostMin': money(total_min * PRICE_2K_STANDARD),
        'standard2KCostMax': money(total_max * PRICE_2K_STANDARD),
        'batch2KCostMin': money(total_min * PRICE_2K_BATCH),
        'batch2KCostMax': money(total_max * PRICE_2K_BATCH),
    }
    print(json.dumps(payload, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
