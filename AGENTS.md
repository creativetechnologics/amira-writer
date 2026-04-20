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

**Canonical doc:** `docs/API.md`. Two interfaces: (1) HTTP JSON API on `localhost:19847` (only reachable once the app is on the Score page); (2) headless full-mix WAV export via env vars on the app bundle. Do **not** use `Scripts/export-headless-wav.sh` or the `Score` package binary — it produces sine tones, not real audio.

## Headless Full-Mix WAV Export (BBC SO)

**Canonical doc:** `docs/HOW-TO-EXPORT-WAV.md`. Every agent must follow it exactly — do not improvise. The constraints listed there exist because every alternative has already been tried and rejected.

TL;DR:

- Launch the built app bundle with `open -W -n --env AMIRA_HEADLESS_FULLMIX_EXPORT=... --env AMIRA_HEADLESS_FULLMIX_SONG=...`. The shipping path is realtime capture with a 4096-frame export buffer (commit `ca679fcf`); it is click-free on BBC SO.
- Do **not** set `AMIRA_HEADLESS_FORCE_OFFLINE` — the offline path produces audible click artifacts.
- Do **not** patch BBC SO, fall back to SF2, or post-process the WAV. BBC SO stays stock; any fix must be in-render.
- Use a specific song hint (e.g. `"Johnny's Goodbye"`) — bare `"Finale"` resolves to Act I Finale, not Johnny's Goodbye Finale.
- Validate end-to-end (`resolved song`, WAV duration, `done status=success`) before asking Gary to listen. Gary is not the tester.

See `docs/HOW-TO-EXPORT-WAV.md` for the full command template, env var reference, verification checklist, flaky-XPC-cold-start remedy, and hard constraints.
