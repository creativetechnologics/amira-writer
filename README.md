# Amira Writer

This folder is the consolidated workspace for the unified `Amira Writer` app.

Canonical product/module names are `Opera`, `WriteUI`, `MixUI`, `Score`, `ScoreUI`, `Animate`, `AnimateUI`, `ProjectKit`, and `ProjectService`. The package container directories and live source folders now use canonical names.

## Layout

- `Sources/Opera`
  - unified app shell and top-level mode switching
- `Sources/WriteUI`
  - Write workspace used inside Opera
- `Sources/MixUI`
  - Mix workspace used inside Opera
- `Packages/ProjectKit/Sources/ProjectKit`
  - shared persistence, project persistence APIs, progress tracking, and Opera chrome
- `Packages/Score/Sources/ScoreUI`
  - Score workspace used inside Opera
- `Packages/Animate/Sources/AnimateUI`
  - Animate workspace used inside Opera
- `history`
  - migration notes, handoff docs, known status

## Build

```bash
# Fast local loop (recommended during development)
rtk /Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-opera-dev.sh
rtk /Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-opera-dev.sh --run

# Release-style build path
rtk /Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh --debug
```

For release-quality validation before shipping:

```bash
rtk swift build -c release --product Opera
rtk swift test -c release
rtk /Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh
```

## Deploy

```bash
rtk /Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh
```

`Scripts/build-app.sh` now installs locally and deploys to both `gary@Garys-Laptop.local:~/Applications/` and `gary@Garys-MacBook.local:~/Applications/` by default. Use `--local-only` to skip remote deployment.

### Quick local workflow

- Open projects from local project folders (with `Metadata/project.json` or `project.json`) for full write/score/animate loading.
- The app is folder-first: choose the project directory directly from disk and it loads entirely local data.
- **The Novotro Project Server is abandoned and disabled.** Do not attempt to use it.
- Headless score export should use `Score` or `Scripts/export-headless-wav.sh`. Project service work should use `ProjectService` / `project-service`.
- Default project location is currently `~/Documents/Amira - A Modern Opera/Amira` (preferred) and
  `~/Documents/Amira - A Modern Opera` (fallback).

The Opera shell opens local project folders directly and builds local indexes for fast mode switching. No server, remote sync, or network project discovery is used.

### Local cache cleanup

When project paths move, old local cache folders can accumulate. Use this repeatable cleanup script:

```bash
rtk Scripts/cleanup-opera-cache.sh
rtk Scripts/cleanup-opera-cache.sh --all-caches
```

You can also point it at a specific project folder:

```bash
rtk Scripts/cleanup-opera-cache.sh --project "$HOME/Documents/Amira - A Modern Opera"
```

## Programmatic Interfaces

Agents and external tools that need to drive the app should read [`docs/API.md`](docs/API.md). It documents:

- The HTTP JSON API on `localhost:19847` (activates once the Score page is loaded) — ~60 endpoints for songs, notes, tempo, playback, export, mixer, versions. **This is the supported WAV-export path for agents: drive the open app.**
- Forbidden paths (e.g. the `Score` package binary, which only produces sine tones).

## Important Note

This workspace is intended to be self-contained for future agents. The legacy sibling repos remain on disk as historical source locations, but new Opera work should happen here.

### Recent Maintenance
- **2026-03-21**: UI Simplification & Cleanup pass. Consolidated duplicate UI components into `ProjectKit` and optimized shell performance. See [history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md](history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md) for details.
