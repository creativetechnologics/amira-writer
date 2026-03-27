# Amira Writer Instructions

## IMPORTANT: Novotro Project Server is DEPRECATED

**The Novotro Project Server is abandoned and will never be used again.**
- Do NOT attempt to use, configure, or reference the Novotro Project Server in any workflow
- Do NOT look for project files in `~/Documents/Novotro Project Server/`
- All project loading is fully local — the app opens project folders directly from disk
- If you encounter code referencing "Project Server", "NovotroProjectServerBrowser", "NovotroProjectServerClient", or similar, ignore it entirely

## Canonical Workspace

- Treat `/Volumes/Storage VIII/Programming/Amira Writer` as the canonical home for the unified Opera app.
- Do not edit Opera features out of the legacy `Novotro Write`, `Novotro Score`, `Novotro Animate`, or `NovotroProjectKit` folders unless a migration task explicitly requires it.
- The unified app shell lives at `Sources/NovotroOpera`.
- The Write workspace lives at `Sources/NovotroWrite`.
- Vendored local packages live at:
  - `Packages/NovotroProjectKit`
  - `Packages/NovotroScore`
  - `Packages/NovotroAnimate`

## Build And Deploy

- Fast local loop (preferred for day-to-day iteration):
  - `rtk /Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-opera-dev.sh`
- Local build:
  - `rtk swift build -c release`
- Local tests:
  - `rtk swift test -c release`
- Bundle build:
  - `rtk /Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh`
- Remote deploy to Gary's user Applications folders:
  - `rtk /Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh`
  - This installs locally, then deploys to both `gary@Garys-Laptop.local:~/Applications/` and `gary@Garys-MacBook.local:~/Applications/` by default.
  - Use `--local-only` to skip remote deployment when needed.

## Handoff Docs

- Start with `README.md`.
- Then read:
  - `history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md`
  - `history/HANDOFF-2026-03-21.md`
  - `history/OPERA-CONSOLIDATION-2026-03-21.md`
  - `history/OPERA-DEVELOPMENT-HISTORY-2026-03-21.md`
