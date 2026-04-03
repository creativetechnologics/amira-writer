#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TierPlan:
    name: str
    total_assets_range: tuple[int, int]
    costume_assets_range: tuple[int, int]


@dataclass(frozen=True)
class Pricing:
    standard_1k: float = 0.067
    standard_2k: float = 0.101
    standard_4k: float = 0.151
    batch_1k: float = 0.034
    batch_2k: float = 0.050
    batch_4k: float = 0.076


TIERS = (
    TierPlan('hero', (90, 140), (18, 28)),
    TierPlan('supporting', (45, 80), (10, 16)),
    TierPlan('background', (18, 35), (6, 10)),
)


def midpoint(bounds: tuple[int, int]) -> int:
    return round((bounds[0] + bounds[1]) / 2)


def money(value: float) -> str:
    return f'${value:,.2f}'


def main() -> None:
    p = Pricing()
    print('Nano Banana 2 / Gemini 3.1 Flash Image Preview cost model')
    print('Pricing:')
    print(f'  Standard 1K {money(p.standard_1k)} | 2K {money(p.standard_2k)} | 4K {money(p.standard_4k)}')
    print(f'  Batch    1K {money(p.batch_1k)} | 2K {money(p.batch_2k)} | 4K {money(p.batch_4k)}')
    print()
    for tier in TIERS:
        mid = midpoint(tier.total_assets_range)
        print(f'{tier.name}: assets {tier.total_assets_range[0]}-{tier.total_assets_range[1]}, per costume {tier.costume_assets_range[0]}-{tier.costume_assets_range[1]}')
        print(f'  midpoint @{mid} assets -> std 1K {money(mid * p.standard_1k)}, std 2K {money(mid * p.standard_2k)}, batch 2K {money(mid * p.batch_2k)}')
    print()
    hero_assets = 120
    print(f'hero package example ({hero_assets} assets): std1K {money(hero_assets * p.standard_1k)}, std2K {money(hero_assets * p.standard_2k)}, std4K {money(hero_assets * p.standard_4k)}, batch2K {money(hero_assets * p.batch_2k)}')


if __name__ == '__main__':
    main()
