#!/usr/bin/env python3
"""
migrate-project-layout.py

Migrates the current Scenes/<slug>/ package layout into the new domain-split layout:

    Write/<title>.md                     ← script markdown
    Write/_versions/<title>/<ts>.md      ← version snapshots
    Write/_versions/<title>/_versions.json
    Score/<title>/score.playback.json
    Scenes/<title>/animation.json
    Scenes/<title>/shots.json
    <project>/scene-index.json           ← canonical identity index

Run with:
    python3 Scripts/migrate-project-layout.py <project-directory>

Use --dry-run to preview without writing.
Use --archive-old to move old Scenes/<slug>/ dirs into _Archive/migrated-<ts>/
"""

import argparse
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


def slug_to_title(scene: dict) -> str:
    """Use the scene.json `title` field, or fall back to slug."""
    t = scene.get("title")
    if t and t.strip():
        return t.strip()
    slug = scene.get("slug", "Unknown")
    return slug.replace("-", " ").title()


def parse_timestamp(ts_str: str) -> datetime:
    """Parse ISO 8601 timestamp, trying common formats."""
    for fmt in [
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S",
    ]:
        try:
            return datetime.strptime(ts_str, fmt)
        except (ValueError, TypeError):
            continue
    return datetime.now(timezone.utc)


def format_filename_ts(dt: datetime) -> str:
    """Format for macOS-safe filename: 2026-02-20T08-56-01Z"""
    return dt.strftime("%Y-%m-%dT%H-%M-%SZ")


def safe_filename(text: str) -> str:
    """Create a filesystem-safe filename from a scene title."""
    safe = text.replace("/", "-").replace(":", "-").replace("\\", "-")
    safe = safe.strip()
    return safe if safe else "untitled"


def load_json(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, data, pretty: bool = True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        if pretty:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        else:
            json.dump(data, f, ensure_ascii=False)


def write_text(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read_text(path: Path) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def main():
    parser = argparse.ArgumentParser(
        description="Migrate Scenes/<slug>/ to Write/ + Score/ + Scenes/"
    )
    parser.add_argument("project", type=str, help="Path to the Amira project directory")
    parser.add_argument("--dry-run", action="store_true", help="Preview only, no writes")
    parser.add_argument("--archive-old", action="store_true", help="Move old Scenes/<slug>/ dirs to _Archive/")
    args = parser.parse_args()

    project = Path(args.project).expanduser().resolve()
    if not project.is_dir():
        print(f"ERROR: {project} is not a directory", file=sys.stderr)
        sys.exit(1)

    scenes_dir = project / "Scenes"
    if not scenes_dir.is_dir():
        print(f"ERROR: {scenes_dir} does not exist", file=sys.stderr)
        sys.exit(1)

    print(f"Migrating {project}")
    print(f"  Reading scenes from {scenes_dir}")
    if args.dry_run:
        print("  DRY RUN — no files will be written")
    print()

    # Discover scene packages
    scene_dirs = sorted([
        d for d in scenes_dir.iterdir()
        if d.is_dir() and (d / "scene.json").is_file()
    ])

    print(f"  Found {len(scene_dirs)} scene packages")
    print()

    scene_index_entries = []
    stats = {
        "write_files": 0,
        "version_files": 0,
        "score_files": 0,
        "shots_files": 0,
        "animation_files": 0,
        "scenes_archived": 0,
        "errors": 0,
    }

    for scene_dir in scene_dirs:
        slug = scene_dir.name
        scene_json_path = scene_dir / "scene.json"

        try:
            scene_data = load_json(scene_json_path)
        except Exception as e:
            print(f"  ERROR reading {scene_json_path}: {e}")
            stats["errors"] += 1
            continue

        scene_id = scene_data.get("id", "unknown")
        title = slug_to_title(scene_data)
        order = scene_data.get("order", 0)
        created_at = scene_data.get("createdAt", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        updated_at = scene_data.get("updatedAt", created_at)
        active_version_id = scene_data.get("activeVersionID")
        version_order = scene_data.get("versionOrder", [])

        versions_meta = scene_data.get("versions", [])
        if not versions_meta:
            print(f"  SKIP {slug}: no versions")
            continue

        # Sort versions by versionOrder
        version_order_map = {vid: i for i, vid in enumerate(version_order)}
        versions_meta_sorted = sorted(versions_meta, key=lambda v: version_order_map.get(v.get("id", ""), 9999))

        # Separate active vs old versions
        active_version = None
        old_versions = []
        for vm in versions_meta_sorted:
            vid = vm.get("id")
            if vid == active_version_id:
                active_version = vm
            else:
                old_versions.append(vm)

        # Fallback: last in order is active
        if active_version is None and versions_meta_sorted:
            active_version = versions_meta_sorted[-1]

        if active_version is None:
            print(f"  SKIP {slug}: no active version")
            continue

        title_safe = safe_filename(title)

        # --- Write/ directory ---
        write_dir = project / "Write"
        write_file = write_dir / f"{title_safe}.md"
        versions_dir = write_dir / "_versions" / title_safe

        # Build frontmatter + body
        version_dir = scene_dir / "versions" / active_version.get("id", "")
        manuscript_path = version_dir / "manuscript.md"
        body = read_text(manuscript_path) if manuscript_path.is_file() else ""

        md_content = f"""---
scene_id: "{scene_id}"
title: "{title}"
order: {order}
---

{body}"""

        if not args.dry_run:
            write_text(write_file, md_content)
        stats["write_files"] += 1
        print(f"  WRITE {write_file.name}")

        # --- _versions/ subdirectory ---
        version_entries = []
        for vm in [active_version] + old_versions:
            vid = vm.get("id")
            label = vm.get("label", "Revision")
            ts = vm.get("updatedAt") or vm.get("createdAt") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            dt = parse_timestamp(ts)
            ts_filename = format_filename_ts(dt)
            ts_file = versions_dir / f"{ts_filename}.md"
            ver_dir = scene_dir / "versions" / vid
            ver_manuscript = ver_dir / "manuscript.md"
            ver_body = read_text(ver_manuscript) if ver_manuscript.is_file() else ""

            if not args.dry_run and ver_body.strip():
                write_text(ts_file, ver_body)
                stats["version_files"] += 1
            elif not ver_body.strip():
                pass  # skip empty versions

            version_entries.append({
                "id": vid,
                "timestamp": ts_filename,
                "label": label,
            })

        versions_json = {"versions": version_entries}
        if not args.dry_run:
            write_json(versions_dir / "_versions.json", versions_json)

        # --- Score/ directory ---
        playback_src = version_dir / "score.playback.json"
        if playback_src.is_file():
            score_dir = project / "Score" / title_safe
            if not args.dry_run:
                score_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(playback_src, score_dir / "score.playback.json")
            stats["score_files"] += 1

        # --- Scenes/ directory (new: animation only) ---
        new_scenes_dir = project / "Scenes" / title_safe

        # animation.json at scene level
        anim_src = scene_dir / "animation.json"
        if anim_src.is_file():
            if not args.dry_run:
                new_scenes_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(anim_src, new_scenes_dir / "animation.json")
            stats["animation_files"] += 1

        # shots.json in version dir
        shots_src = version_dir / "shots.json"
        if shots_src.is_file():
            if not args.dry_run:
                shots_dir = project / "Scenes" / title_safe
                shots_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(shots_src, shots_dir / "shots.json")
            stats["shots_files"] += 1

        # Build scene-index entry
        scene_index_entries.append({
            "id": scene_id,
            "title": title,
            "order": order,
            "createdAt": created_at,
            "updatedAt": updated_at,
        })

        # Archive old Scenes/<slug>/ dir
        if args.archive_old and not args.dry_run:
            ts_str = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            archive_dir = project / "_Archive" / f"migrated-{ts_str}"
            shutil.move(str(scene_dir), str(archive_dir / slug))
            stats["scenes_archived"] += 1

    # Write scene-index.json at project root
    index_data = {
        "schemaVersion": 1,
        "scenes": scene_index_entries,
    }
    if not args.dry_run:
        write_json(project / "scene-index.json", index_data)

    print()
    print("=== Migration Summary ===")
    print(f"  Write files:       {stats['write_files']}")
    print(f"  Version files:     {stats['version_files']}")
    print(f"  Score playback:    {stats['score_files']}")
    print(f"  Scenes animation:  {stats['animation_files']}")
    print(f"  Scenes shots:      {stats['shots_files']}")
    print(f"  Archived (old):    {stats['scenes_archived']}")
    if stats["errors"]:
        print(f"  Errors:            {stats['errors']}")
    print(f"  Scene-index:       1")
    print()

    if args.dry_run:
        print("DRY RUN completed. No files were written.")
    else:
        print("Migration complete.")
        print("  -> Open Write/ in Obsidian")
        print("  -> Old Scenes/<slug>/ dirs can be archived with --archive-old")


if __name__ == "__main__":
    main()
