#!/usr/bin/env python3
"""
Wave D disk migration for Amira Writer project data.

Target project root (hard-coded for safety):
  /Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/

Operations (all within the same volume, so os.rename is atomic — iCloud/Syncthing safe):
  1. Animate/characters/<slug>/**  -> Characters/<slug>/**
  2. Animate/imagine/**            -> Scenes/imagine/**
  3. Animate/scenes.json           -> Scenes/scenes.json
  4. Animate/places*.json*, drawThingsPlacesConfig.json, draw-things-places.json -> Places/
  5. Animate/audio/                -> _Archive/Animate-audio/
  6. Animate/3d/                   -> _Archive/Animate-3d/
  7. Instruments.json (root)       -> Settings/instruments.json
  8. config/api-credentials.json   -> Settings/api-credentials.json (then remove empty config/)
  9. Create empty Suno/covers/ and Suno/logs/

Explicitly NOT touched:
  - Syncthing markers (.stfolder, .stignore)
  - Any *.sync-conflict* files
  - Root .md / text files
  - Audio/, Inspiration/, Songs/, Research/, Synopsis/, Write/, ChatHistory/, SoundFonts/,
    Metadata/, Removed From Active Show/
  - Mix/exports/** (no covers exist yet; routing handled in Wave E)
  - Other Animate/ cruft (backgrounds, cache, costumes, debug, generated, objects,
    review-state-backups, scene-generation, reference-registry.*, shot-presets.json,
    character-package-selections.json, animate.json*) — flagged for follow-up pass.

Usage:
  python3 Scripts/wave-d-migration.py              # dry-run (default)
  python3 Scripts/wave-d-migration.py --execute    # actually move bytes
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

# ---- Config --------------------------------------------------------------

PROJECT_ROOT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")

CHARACTER_SLUGS = [
    "amira-nazari",
    "johnny-ward",
    "luke-hart",
    "mark-price",
    "matt-quill",
    "yasmin-nazari",
]

# Places-related files (exact names; globbed at runtime too to catch stragglers).
PLACES_FILES_EXPLICIT = [
    "draw-things-places.json",
    "drawThingsPlacesConfig.json",
    "places-generated-review-events.jsonl",
    "places-generated-review-state.json",
    "places-generated-review-state.previous.json",
    "places-master-map-layers.json",
    "places-workflow.json",
    "places-workflow.previous.json",
    "places-world-context.json",
    "places-world-context.previous.json",
    "places-world-map-canon.json",
    "places-world-map-canon.previous.json",
    "places.json",
    "places.json.bak-20260412T232606",
    "places.previous.json",
    "places.people_briefs.json",
]


# ---- Op model ------------------------------------------------------------

@dataclass
class Op:
    kind: str  # "move" | "mkdir" | "rmdir_empty"
    src: Path | None
    dst: Path | None
    note: str = ""

    def describe(self) -> str:
        if self.kind == "move":
            return f"MOVE   {self._rel(self.src)}  ->  {self._rel(self.dst)}"
        if self.kind == "mkdir":
            return f"MKDIR  {self._rel(self.dst)}"
        if self.kind == "rmdir_empty":
            return f"RMDIR  {self._rel(self.src)}  (empty)"
        return f"?????  {self}"

    def _rel(self, p: Path | None) -> str:
        if p is None:
            return "<none>"
        try:
            return str(p.relative_to(PROJECT_ROOT))
        except ValueError:
            return str(p)


# ---- Plan ----------------------------------------------------------------

def plan_ops() -> list[Op]:
    ops: list[Op] = []

    # 1. Characters/<slug> — create root, move each slug folder
    characters_root = PROJECT_ROOT / "Characters"
    ops.append(Op("mkdir", None, characters_root, note="new top-level"))
    for slug in CHARACTER_SLUGS:
        src = PROJECT_ROOT / "Animate" / "characters" / slug
        dst = characters_root / slug
        if src.exists():
            ops.append(Op("move", src, dst))
    # 1b. Remove empty Animate/characters/ after slugs move
    ops.append(Op("rmdir_empty", PROJECT_ROOT / "Animate" / "characters", None))

    # 2. Scenes/imagine (move the whole imagine/ dir as one op — rename is atomic)
    scenes_root = PROJECT_ROOT / "Scenes"
    ops.append(Op("mkdir", None, scenes_root, note="new top-level"))
    src_imagine = PROJECT_ROOT / "Animate" / "imagine"
    dst_imagine = scenes_root / "imagine"
    if src_imagine.exists():
        ops.append(Op("move", src_imagine, dst_imagine))

    # 3. Scenes/scenes.json
    src_scenes = PROJECT_ROOT / "Animate" / "scenes.json"
    dst_scenes = scenes_root / "scenes.json"
    if src_scenes.exists():
        ops.append(Op("move", src_scenes, dst_scenes))

    # 4. Places/ — create root, move all places-* files (plus draw-things-places variants)
    places_root = PROJECT_ROOT / "Places"
    ops.append(Op("mkdir", None, places_root, note="new top-level"))
    animate_dir = PROJECT_ROOT / "Animate"
    moved_place_names: set[str] = set()
    for name in PLACES_FILES_EXPLICIT:
        src = animate_dir / name
        if src.exists():
            ops.append(Op("move", src, places_root / name))
            moved_place_names.add(name)
    # Catch any other place-* files we didn't enumerate (defensive glob)
    for extra in sorted(animate_dir.glob("places*")):
        if extra.name not in moved_place_names and extra.is_file():
            ops.append(
                Op("move", extra, places_root / extra.name, note="glob-caught places-*")
            )

    # 5. _Archive/Animate-audio/ and Animate-3d/
    archive_root = PROJECT_ROOT / "_Archive"
    ops.append(Op("mkdir", None, archive_root, note="new archive root"))
    for folder in ["audio", "3d"]:
        src = animate_dir / folder
        dst = archive_root / f"Animate-{folder}"
        if src.exists():
            ops.append(Op("move", src, dst, note="archive"))

    # 6. Settings/instruments.json (root-level Instruments.json)
    src_instruments = PROJECT_ROOT / "Instruments.json"
    dst_instruments = PROJECT_ROOT / "Settings" / "instruments.json"
    if src_instruments.exists():
        ops.append(Op("move", src_instruments, dst_instruments, note="lowercased"))

    # 7. Settings/api-credentials.json
    src_creds = PROJECT_ROOT / "config" / "api-credentials.json"
    dst_creds = PROJECT_ROOT / "Settings" / "api-credentials.json"
    if src_creds.exists():
        ops.append(Op("move", src_creds, dst_creds))
    ops.append(
        Op("rmdir_empty", PROJECT_ROOT / "config", None, note="after creds moves")
    )

    # 8. Suno/covers and Suno/logs (empty dirs, Wave E routing targets)
    for sub in ["covers", "logs"]:
        target = PROJECT_ROOT / "Suno" / sub
        ops.append(Op("mkdir", None, target, note="Wave E target"))

    return ops


# ---- Validation / execution ---------------------------------------------

def validate(ops: Iterable[Op]) -> list[str]:
    """Return list of error strings; empty means safe to execute."""
    errors: list[str] = []
    planned_dsts: set[Path] = set()
    for op in ops:
        if op.kind == "move":
            assert op.src is not None and op.dst is not None
            if not op.src.exists():
                errors.append(f"MISSING SRC: {op.src}")
            if op.dst.exists():
                errors.append(f"DST EXISTS:  {op.dst}")
            if op.dst in planned_dsts:
                errors.append(f"DUPLICATE DST: {op.dst}")
            planned_dsts.add(op.dst)
            # cross-volume check (atomic rename only within same volume)
            try:
                src_dev = op.src.stat().st_dev
                parent = op.dst.parent
                # walk up until we hit an existing ancestor to check device
                while not parent.exists():
                    parent = parent.parent
                dst_dev = parent.stat().st_dev
                if src_dev != dst_dev:
                    errors.append(f"CROSS-VOLUME MOVE: {op.src} -> {op.dst}")
            except OSError as exc:
                errors.append(f"STAT ERROR: {op.src} / {op.dst}: {exc}")
    return errors


def execute(ops: Iterable[Op]) -> None:
    for op in ops:
        if op.kind == "mkdir":
            assert op.dst is not None
            op.dst.mkdir(parents=True, exist_ok=True)
            print(f"  mkdir  {op.dst}")
        elif op.kind == "move":
            assert op.src is not None and op.dst is not None
            op.dst.parent.mkdir(parents=True, exist_ok=True)
            # os.rename (via shutil.move) = atomic on same volume, iCloud/Syncthing safe.
            shutil.move(str(op.src), str(op.dst))
            print(f"  moved  {op.src}  ->  {op.dst}")
        elif op.kind == "rmdir_empty":
            assert op.src is not None
            if op.src.exists():
                try:
                    op.src.rmdir()
                    print(f"  rmdir  {op.src}")
                except OSError as exc:
                    print(f"  skip rmdir {op.src}: {exc}")
            else:
                print(f"  skip rmdir {op.src}: already gone")


# ---- Main ----------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Perform the moves. Default is dry-run.",
    )
    args = parser.parse_args()

    if not PROJECT_ROOT.exists():
        print(f"Project root not found: {PROJECT_ROOT}", file=sys.stderr)
        return 2

    ops = plan_ops()

    print(f"Wave D migration — {'EXECUTE' if args.execute else 'DRY-RUN'}")
    print(f"Project root: {PROJECT_ROOT}")
    print(f"Operations planned: {len(ops)}")
    print("-" * 72)
    for op in ops:
        suffix = f"   [{op.note}]" if op.note else ""
        print(f"  {op.describe()}{suffix}")
    print("-" * 72)

    errors = validate(ops)
    if errors:
        print(f"VALIDATION FAILED ({len(errors)} issue(s)):")
        for err in errors:
            print(f"  ! {err}")
        return 1
    print("Validation: OK")

    if not args.execute:
        print("\n(dry-run — pass --execute to actually move bytes)")
        return 0

    print("\nExecuting…")
    execute(ops)
    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
