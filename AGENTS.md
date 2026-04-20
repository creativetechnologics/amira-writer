# Amira Writer Instructions

## IMPORTANT: Novotro Project Server is DEPRECATED

**The Novotro Project Server is abandoned and will never be used again.**
- Do NOT attempt to use, configure, or reference the Novotro Project Server in any workflow
- Do NOT look for project files in `~/Documents/Novotro Project Server/`
- All project loading is fully local — the app opens project folders directly from disk
- If you encounter code referencing "Project Server", "NovotroProjectServerBrowser", "NovotroProjectServerClient", or similar, ignore it entirely

## Canonical Workspace

- Treat `/Volumes/Storage VIII/Programming/Amira Writer` as the canonical home for the unified Opera app.
- Do not edit Opera features out of the legacy `Novotro Write`, `Novotro Score`, or `Novotro Animate` folders unless a migration task explicitly requires it.
- The unified app shell lives at `Sources/Opera`.
- The Write workspace lives at `Sources/WriteUI`.
- Vendored local packages live at:
  - `Packages/ProjectKit`
  - `Packages/Score`
  - `Packages/Animate`

## Canonical Names

- Use these names in builds, scripts, imports, and LLM instructions:
  - `Opera`
  - `WriteUI`
  - `MixUI`
  - `Score`
  - `ScoreUI`
  - `Animate`
  - `AnimateUI`
- `ProjectKit`
- `ProjectService` / `project-service`
- Do not direct agents toward `NovotroOpera`, `NovotroScore`, `NovotroAnimate`, `NovotroWriteUI`, `NovotroMixUI`, `NovotroScoreUI`, `NovotroAnimateUI`, or `novotro-project-service` unless you are deliberately working on compatibility internals.
- The package container directories now use canonical names such as `Packages/ProjectKit`, `Packages/Score`, and `Packages/Animate`, and the live source folders use canonical names such as `Sources/Opera`, `Sources/WriteUI`, `Packages/Score/Sources/ScoreUI`, `Packages/Animate/Sources/AnimateUI`, and `Packages/ProjectKit/Sources/ProjectKit`.

## Build And Deploy

- Fast local loop (preferred for day-to-day iteration):
  - `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-opera-dev.sh`
- Local build:
  - `swift build -c release --product Opera`
- Local tests:
  - `swift test -c release`
- Bundle build:
  - `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh`
- Remote deploy to Gary's user Applications folders:
  - `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh`
  - This installs locally, then deploys to both `gary@Garys-Laptop.local:~/Applications/` and `gary@Garys-MacBook.local:~/Applications/` by default.
  - Use `--local-only` to skip remote deployment when needed.

## Handoff Docs

- Start with `README.md`.
- Then read:
  - `history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md`
  - `history/HANDOFF-2026-03-21.md`
  - `history/OPERA-CONSOLIDATION-2026-03-21.md`
  - `history/OPERA-DEVELOPMENT-HISTORY-2026-03-21.md`

## Programmatic Interfaces (API)

**Canonical doc:** `docs/API.md` — HTTP JSON API on `localhost:19847`, active once the app is open and on the Score page. Use this for WAV export (`/export/full-mix`), song/note/tempo/playback/mixer/version operations (~60 endpoints).

Do **not** use `Scripts/export-headless-wav.sh` or the `Score` package binary — they produce sine tones, not real audio.

The env-var headless full-mix export path (`AMIRA_HEADLESS_FULLMIX_EXPORT`) is **not** a supported agent workflow: it was documented once and retired because it did not work reliably end-to-end from an agent context. If you need a WAV headlessly, drive the open app via the HTTP API.
