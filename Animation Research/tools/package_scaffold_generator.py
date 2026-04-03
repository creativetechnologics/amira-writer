#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

TIER_DEFAULTS = {
    'hero': {'motionPrimitives': 14, 'mouthProfiles': 5},
    'supporting': {'motionPrimitives': 8, 'mouthProfiles': 3},
    'background': {'motionPrimitives': 4, 'mouthProfiles': 1},
}


def slugify(value: str) -> str:
    return '-'.join(part for part in ''.join(ch.lower() if ch.isalnum() else ' ' for ch in value).split() if part)


def build_manifest(name: str, tier: str, costumes: list[str]) -> dict:
    slug = slugify(name)
    defaults = TIER_DEFAULTS[tier]
    costume_packs = []
    for costume in costumes:
        cid = slugify(costume)
        costume_packs.append({
            'id': f'costume_{cid}',
            'label': costume,
            'sheetAssetID': f'sheet_body_{slug}_{cid}',
            'accessorySetIDs': []
        })
    mouth_profiles = []
    for angle in ['front', 'quarterLeft', 'quarterRight', 'profileLeft', 'profileRight'][:defaults['mouthProfiles']]:
        mouth_profiles.append({'id': f'mouth_{angle}_{slug}', 'angleFamily': angle})
    motion = []
    seeds = ['idle', 'walk', 'turn', 'reach', 'react', 'sit', 'stand', 'look']
    for idx, name_seed in enumerate(seeds[:defaults['motionPrimitives']]):
        motion.append({'id': f'{name_seed}_{idx + 1}', 'name': name_seed})
    return {
        'schemaVersion': 1,
        'packageId': f'{slug}-vnext',
        'characterIdentity': {
            'characterId': slug,
            'displayName': name,
            'identityReferences': [],
            'masterSheetAssetID': f'sheet_master_{slug}',
            'headSheetAssetID': f'sheet_head_{slug}'
        },
        'costumePacks': costume_packs,
        'mouthProfiles': mouth_profiles,
        'motionPrimitives': motion,
        'assetFamilies': {
            'masterSheets': [f'sheet_master_{slug}'],
            'headSheets': [f'sheet_head_{slug}'],
            'bodySheets': [pack['sheetAssetID'] for pack in costume_packs]
        },
        'defaults': {
            'defaultCostumePackID': costume_packs[0]['id'] if costume_packs else None,
            'defaultMouthProfileID': mouth_profiles[0]['id'] if mouth_profiles else None
        },
        'qa': {'status': 'draft'}
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('name')
    parser.add_argument('--tier', choices=sorted(TIER_DEFAULTS), default='hero')
    parser.add_argument('--costume', action='append', dest='costumes', default=[])
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    manifest = build_manifest(args.name, args.tier, args.costumes or ['Default'])
    text = json.dumps(manifest, indent=2)
    if args.out:
        args.out.write_text(text + '\n')
    else:
        print(text)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
