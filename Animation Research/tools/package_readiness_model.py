#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ScoreCard:
    identity: float
    costume: float
    facial: float
    motion: float
    technical: float

    @property
    def weighted(self) -> float:
        return (
            self.identity * 0.25
            + self.costume * 0.20
            + self.facial * 0.20
            + self.motion * 0.20
            + self.technical * 0.15
        )


def ratio(hit: int, total: int) -> float:
    return 1.0 if total <= 0 else max(0.0, min(1.0, hit / total))


def score_manifest(payload: dict) -> tuple[ScoreCard, list[str]]:
    problems: list[str] = []
    identity = ratio(sum(bool(payload.get('characterIdentity', {}).get(key)) for key in ['identityReferences', 'masterSheetAssetID', 'headSheetAssetID']), 3)
    if not payload.get('characterIdentity', {}).get('masterSheetAssetID'):
        problems.append('Missing master sheet asset')
    if not payload.get('characterIdentity', {}).get('headSheetAssetID'):
        problems.append('Missing head sheet asset')

    costume_packs = payload.get('costumePacks', [])
    costume = ratio(sum(1 for pack in costume_packs if pack.get('sheetAssetID')), max(1, len(costume_packs)))
    if not costume_packs:
        problems.append('No costume packs defined')

    mouth_profiles = payload.get('mouthProfiles', [])
    facial = ratio(len(mouth_profiles), 3)
    if not mouth_profiles:
        problems.append('No mouth profiles defined')

    primitive_names = {p.get('name', '').lower() for p in payload.get('motionPrimitives', [])}
    needed = ['idle', 'walk', 'turn', 'reach', 'react']
    motion = ratio(sum(1 for need in needed if any(need in name for name in primitive_names)), len(needed))
    for need in needed:
        if not any(need in name for name in primitive_names):
            problems.append(f'Missing motion primitive: {need}')

    technical_hits = 0
    if payload.get('assetFamilies'):
        technical_hits += 1
    if payload.get('qa'):
        technical_hits += 1
    if payload.get('defaults'):
        technical_hits += 1
    if payload.get('placementMaps') or payload.get('generationBlueprints'):
        technical_hits += 1
    technical = ratio(technical_hits, 4)

    return ScoreCard(identity, costume, facial, motion, technical), problems


def status_from_score(score: ScoreCard, problems: list[str]) -> str:
    if 'Missing master sheet asset' in problems or 'No mouth profiles defined' in problems:
        return 'draft'
    if score.identity >= 0.95 and score.facial >= 0.90 and score.motion >= 0.85 and score.costume >= 0.85 and score.technical >= 0.95:
        return 'production-ready'
    if score.identity >= 0.90 and score.facial >= 0.85 and score.motion >= 0.75 and score.costume >= 0.70 and score.technical >= 0.90:
        return 'performance-ready'
    if score.identity >= 0.90 and score.facial >= 0.75 and score.motion >= 0.50 and score.technical >= 0.80:
        return 'dialogue-ready'
    return 'blocking-ready'


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: package_readiness_model.py <package-json>')
        return 2
    payload = json.loads(Path(sys.argv[1]).read_text())
    score, problems = score_manifest(payload)
    print(f'Readiness: {status_from_score(score, problems)}')
    print(f'Weighted score: {score.weighted:.2f}')
    print(f'Identity:  {score.identity:.2f}')
    print(f'Costume:   {score.costume:.2f}')
    print(f'Facial:    {score.facial:.2f}')
    print(f'Motion:    {score.motion:.2f}')
    print(f'Technical: {score.technical:.2f}')
    if problems:
        print('Problems:')
        for item in problems:
            print(f'- {item}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
