#!/usr/bin/env python3
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any

ANIMATE_ROOT = Path('/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate')
BACKGROUND_REF_ROOT = ANIMATE_ROOT / 'backgrounds' / 'chosen-references'
COSTUME_REF_ROOT = ANIMATE_ROOT / 'costumes'
OUTPUT_JSON = ANIMATE_ROOT / 'reference-registry.json'
OUTPUT_MD = ANIMATE_ROOT / 'reference-registry.md'


def file_entry(path: Path, root: Path) -> dict[str, Any]:
    return {
        'name': path.name,
        'absolute_path': str(path),
        'relative_to_root': str(path.relative_to(root)),
    }


def background_guidance(folder_name: str) -> dict[str, Any]:
    key = folder_name.lower()
    if key == 'map':
        return {
            'kind': 'background_layout_anchor',
            'priority': 1,
            'use_for': [
                'all outdoor valley shots',
                'broad establishing shots',
                'any image where geography continuity matters',
                'shots that must preserve town / bridge / cemetery / base placement',
            ],
            'guidance': 'Feed map refs first whenever the shot is outdoors or layout continuity matters. Treat map as the master world-layout reference.',
        }
    if key == 'bridge':
        return {
            'kind': 'background_design_anchor',
            'priority': 2,
            'use_for': [
                'bridge hero shots',
                'bridge-adjacent exteriors',
                'crossing approach shots',
                'any frame where bridge form, deck width, or masonry design matters',
            ],
            'guidance': 'Combine bridge refs with the map for bridge scenes. Use bridge refs for form/design and map for placement/context.',
        }
    return {
        'kind': 'background_design_anchor',
        'priority': 3,
        'use_for': [f'{folder_name} related background/environment shots'],
        'guidance': f'Use {folder_name} refs when that specific environmental motif needs to stay consistent.',
    }


def costume_guidance(folder_name: str) -> dict[str, Any]:
    return {
        'kind': 'costume_anchor',
        'priority': 1,
        'use_for': [
            f'{folder_name} wardrobe continuity',
            'character clothing consistency',
            'gear / silhouette / fabric reference for matching scenes',
        ],
        'guidance': f'Use these refs whenever a shot includes {folder_name} wardrobe or adjacent costume continuity concerns.',
    }


def scan_dir(root: Path, guidance_fn) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    if not root.exists():
        return entries
    for folder in sorted([p for p in root.iterdir() if p.is_dir()]):
        files = sorted([p for p in folder.iterdir() if p.is_file()])
        guidance = guidance_fn(folder.name)
        entries.append({
            'name': folder.name,
            'absolute_path': str(folder),
            'file_count': len(files),
            'files': [file_entry(f, root) for f in files],
            **guidance,
        })
    return entries


def build_registry() -> dict[str, Any]:
    background_entries = scan_dir(BACKGROUND_REF_ROOT, background_guidance)
    costume_entries = scan_dir(COSTUME_REF_ROOT, costume_guidance)
    return {
        'updated_at': datetime.now().isoformat(),
        'animate_root': str(ANIMATE_ROOT),
        'rules': {
            'outdoor_default': 'For outdoor scenes, feed map refs whenever geography continuity matters.',
            'bridge_default': 'For bridge scenes, feed map refs plus bridge refs; map controls placement, bridge refs control design.',
            'interior_default': 'For interiors, skip map unless exterior geography is visible or continuity is important for windows/doorways.',
            'costume_default': 'For character scenes, combine relevant costume refs with location refs as needed.',
            'no_collage_default': 'Feed chosen refs as separate images, not as a collage, unless the user explicitly requests a collage.',
        },
        'backgrounds': background_entries,
        'costumes': costume_entries,
    }


def write_markdown(registry: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append('# Amira Reference Registry')
    lines.append('')
    lines.append(f"Updated: {registry['updated_at']}")
    lines.append('')
    lines.append('## Global rules')
    lines.append('')
    for key, value in registry['rules'].items():
        lines.append(f'- **{key}**: {value}')
    lines.append('')
    lines.append('## Background chosen references')
    lines.append('')
    if not registry['backgrounds']:
        lines.append('_None found._')
    for entry in registry['backgrounds']:
        lines.append(f"### {entry['name']}")
        lines.append('')
        lines.append(f"- Kind: {entry['kind']}")
        lines.append(f"- Priority: {entry['priority']}")
        lines.append(f"- Folder: `{entry['absolute_path']}`")
        lines.append(f"- Guidance: {entry['guidance']}")
        lines.append('- Use for:')
        for use_case in entry['use_for']:
            lines.append(f'  - {use_case}')
        lines.append('- Files:')
        for file_info in entry['files']:
            lines.append(f"  - `{file_info['absolute_path']}`")
        lines.append('')
    lines.append('## Costume references')
    lines.append('')
    if not registry['costumes']:
        lines.append('_None found._')
    for entry in registry['costumes']:
        lines.append(f"### {entry['name']}")
        lines.append('')
        lines.append(f"- Kind: {entry['kind']}")
        lines.append(f"- Priority: {entry['priority']}")
        lines.append(f"- Folder: `{entry['absolute_path']}`")
        lines.append(f"- Guidance: {entry['guidance']}")
        lines.append('- Use for:')
        for use_case in entry['use_for']:
            lines.append(f'  - {use_case}')
        lines.append('- Files:')
        for file_info in entry['files']:
            lines.append(f"  - `{file_info['absolute_path']}`")
        lines.append('')
    return '\n'.join(lines).rstrip() + '\n'


def main() -> None:
    registry = build_registry()
    OUTPUT_JSON.write_text(json.dumps(registry, indent=2), encoding='utf-8')
    OUTPUT_MD.write_text(write_markdown(registry), encoding='utf-8')
    print(OUTPUT_JSON)
    print(OUTPUT_MD)


if __name__ == '__main__':
    main()
