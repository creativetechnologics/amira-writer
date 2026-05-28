# Project Directory Reorganization — Write/Score/Scenes/Mix

**Branch:** `project-reorganization`
**Date:** 2026-05-27
**Status:** In progress

## Goal

Split the monolithic `Scenes/<slug>/` package layout into four domain directories
that match the app's sidebar tabs: `Write/`, `Score/`, `Scenes/`, `Mix/`.

- `Write/` is an Obsidian-compatible vault of flat `.md` files
- `Score/` has per-scene folders with playback data
- `Scenes/` has per-scene folders with animation data
- Folders are the source of truth; SQLite is a derived cache

## Target Directory Layout

```
<project>/
├── scene-index.json                       ← Canonical identity index
├── Write/                                 ← Obsidian vault
│   ├── 1.03.0 - Scene - Luke's Notebook.md
│   ├── 1.04.0 - Scene - Assignment.md
│   ├── ...
│   └── _versions/
│       ├── 1.03.0 - Scene - Luke's Notebook/
│       │   ├── _versions.json
│       │   ├── 2026-02-20T08-56-01Z.md
│       │   └── 2026-03-15T14-30-00Z.md
│       └── 1.04.0 - Scene - Assignment/
│           └── ...
├── Score/
│   ├── 1.03.0 - Scene - Luke's Notebook/
│   │   └── score.playback.json
│   └── 1.04.0 - Scene - Assignment/
│       └── score.playback.json
├── Scenes/
│   ├── 1.03.0 - Scene - Luke's Notebook/
│   │   ├── animation.json
│   │   └── shots.json
│   ├── imagine/                           ← Project-level, unmoved
│   └── 1.04.0 - Scene - Assignment/
│       └── ...
├── Mix/                                   ← Unchanged
├── Characters/                            ← Unchanged
├── Settings/                              ← Unchanged
└── .amira/project.sqlite                  ← Derived cache only
```

## Canonical Files

### `scene-index.json` (project root)

```json
{
  "schemaVersion": 1,
  "scenes": [
    {
      "id": "22023608-71f8-49b1-bcee-c7698cc781d7",
      "title": "1.03.0 - Scene - Luke's Notebook",
      "order": 1030000,
      "createdAt": "2026-02-20T08:56:01Z",
      "updatedAt": "2026-05-27T10:00:00Z"
    }
  ]
}
```

- `id` — UUID, universal key across all domains
- `title` — human name with prefix (e.g. `1.03.0 - Scene - Luke's Notebook`)
- `order` — big integer sort key (act * 1000000 + scene * 10000 + movement)
- `createdAt` / `updatedAt` — ISO 8601

### `Write/<title>.md`

```markdown
---
scene_id: "22023608-71f8-49b1-bcee-c7698cc781d7"
title: "1.03.0 - Scene - Luke's Notebook"
order: 1030000
---

## Speaker or action heading

	TAB-INDENTED LYRIC
	MORE LYRIC

## Next action heading

	OTHER CHARACTER
		Their lyric here
```

Frontmatter: `scene_id`, `title`, `order`. Body: verbatim manuscript.md content
(## headers, tab-indented lyrics). No bracket DSL markup.

### `Write/_versions/<title>/_versions.json`

```json
{
  "versions": [
    {
      "id": "ce057d8a-e511-4ea7-8cb1-a448ac9db2af",
      "timestamp": "2026-02-20T08-56-01Z",
      "label": "Initial import"
    }
  ]
}
```

Each version is a `.md` file named `<timestamp>.md` in the same directory.

### `Score/<title>/score.playback.json`

Unchanged from current format. Active version only (v1).

### `Scenes/<title>/animation.json` + `Scenes/<title>/shots.json`

Unchanged from current format. Active version only (v1).

## Source of Truth

**Files are the source of truth.** SQLite is a derived cache rebuilt on launch
via `ProjectDatabase.importProjectIndex()` (already the current behavior).

SQLite keeps:
- Image library metadata, batch tracking, review states
- Asset references, file paths
- Activity/change log
- Character metadata cache

SQLite drops from `scenes`/`scene_versions` tables:
- `title`, `canonical_title`, `order_index`, `notes`, `updated_at` (→ scene-index.json)
- `lyrics` text (→ Write/*.md)
- `playback_json` BLOB (→ Score/<title>/score.playback.json)
- `animate_scene_json` BLOB (→ Scenes/<title>/animation.json)
- `root_json` BLOB (→ scene-index.json)

## Data Migration

| Old | New |
|-----|-----|
| `Scenes/<slug>/scene.json` metadata | `scene-index.json` entry |
| `Scenes/<slug>/versions/<activeUUID>/manuscript.md` | `Write/<title>.md` |
| `Scenes/<slug>/versions/<oldUUID>/manuscript.md` | `Write/_versions/<title>/<timestamp>.md` |
| `scene.json` versions array metadata | `Write/_versions/<title>/_versions.json` |
| `Scenes/<slug>/versions/<activeUUID>/score.playback.json` | `Score/<title>/score.playback.json` |
| `Scenes/<slug>/versions/<activeUUID>/shots.json` | `Scenes/<title>/shots.json` |
| `Scenes/<slug>/animation.json` | `Scenes/<title>/animation.json` |
| `Scenes/<slug>/migration.json` | Deleted |
| `Scenes/<slug>/versions/*/script.json` | Deleted |
| `Scenes/<slug>/versions/*/score.metrics.json` | Deleted |
| `Scenes/scene-index.json` | `scene-index.json` (project root) |
| `Scenes/imagine/` | `Scenes/imagine/` (unmoved) |

Title derivation: `scene.json` `slug` → lookup in `scene.json` `title` → use as folder name.
If `title` is empty, use the `slug` converted to title case.

## Scene Reconciliation

| User action | App response |
|------------|-------------|
| Rename file in Obsidian `old.md` → `new.md` | Match by `scene_id` in frontmatter → update `scene-index.json` title → rename `Score/<old>/` and `Scenes/<old>/` |
| Renumber `1.04.0` → `1.05.0` | Update `scene-index.json` order → rename Write/ file → rename Score/ and Scenes/ dirs |
| Create new .md in Write/ | Sidebar: "Import as new scene?" → create index entry + Score/ + Scenes/ folders |
| Delete .md from Write/ | Sidebar: "Archive scene?" → move Score/ + Scenes/ dirs to `_Archive/` |

LLM agents handle bulk rename/reorder by writing to filesystem + updating scene-index.json.

## Bidirectional Sync

- **App writes** on save → export to `Write/<title>.md` → set guard flag → file watcher ignores
- **Obsidian writes** → file watcher detects → reads frontmatter → matches by `scene_id` → updates in-memory document → live update in editor if scene is open
- Existing 0.5s poll interval (ScriptStore) extended to watch Write/
- No new infrastructure needed

## Implementation Phases

| # | Phase | Description |
|---|-------|-------------|
| 1 | ProjectPaths | Add `write`, `scoreDir`, `scenesDir` paths |
| 2 | SceneIndexStore | Read/write `scene-index.json` |
| 3 | Migration script | Python: split Scenes/ tree into 4 domains |
| 4 | WriteSyncStore | Export .md on load + watcher + import on change |
| 5 | VersionStore | `_versions/` management, timestamped snapshots |
| 6 | OWPProjectIO update | Read from `Score/<title>/` not `Scenes/<slug>/` |
| 7 | AnimateProjectBridge update | Read from `Scenes/<title>/` |
| 8 | SQLite cache slim | Remove duplicate fields from schema |

## Open Questions

- Active version tracking: `scene-index.json` has no `activeVersion` field yet.
  For v1, write `manuscript.md` content directly to `Write/<title>.md` and store
  previous versions in `_versions/`. Score/Scenes use the latest playback/shots
  data on disk. Version tracking via `_versions.json` is sufficient for Write;
  Score/Scenes versioning can follow later.
