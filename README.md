# Novotro Opera

This folder is the consolidated workspace for the unified `Novotro Opera` app.

## Layout

- `Sources/NovotroOpera`
  - unified app shell and top-level mode switching
- `Sources/NovotroWrite`
  - Write workspace used inside Opera
- `Packages/NovotroProjectKit`
  - shared persistence, project persistence APIs, progress tracking, and Opera chrome
- `Packages/NovotroScore`
  - Score workspace used inside Opera
- `Packages/NovotroAnimate`
  - Animate workspace used inside Opera
- `history`
  - migration notes, handoff docs, known status

## Build

```bash
# Fast local loop (recommended during development)
rtk /Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/build-opera-dev.sh
rtk /Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/build-opera-dev.sh --run

# Release-style build path
rtk /Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/build-app.sh --debug
```

For release-quality validation before shipping:

```bash
rtk swift build -c release
rtk swift test -c release
rtk /Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/build-app.sh
```

## Deploy

```bash
rtk scp -r "$HOME/Applications/Novotro Opera.app" gary@Garys-Laptop.local:~/Applications/
```

### Quick local workflow

- Open projects from local project folders (with `Metadata/project.json` or `project.json`) for full write/score/animate loading.
- The app is folder-first: choose the project directory directly from disk and it loads entirely local data.
- **The Novotro Project Server is abandoned and disabled.** Do not attempt to use it.
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

## Important Note

This workspace is intended to be self-contained for future agents. The legacy sibling repos remain on disk as historical source locations, but new Opera work should happen here.

### Recent Maintenance
- **2026-03-21**: UI Simplification & Cleanup pass. Consolidated duplicate UI components into `NovotroProjectKit` and optimized shell performance. See [history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md](history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md) for details.

