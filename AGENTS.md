# Amira Writer Instructions

## IMPORTANT: Novotro Project Server is DEPRECATED

**The Novotro Project Server is abandoned and will never be used again.**
- Do NOT attempt to use, configure, or reference the Novotro Project Server in any workflow
- Do NOT look for project files in `~/Documents/Novotro Project Server/`
- All project loading is fully local — the app opens project folders directly from disk
- If you encounter code referencing "Project Server", "NovotroProjectServerBrowser", "NovotroProjectServerClient", or similar, ignore it entirely

## Canonical Workspace

- Treat `/Volumes/Storage VIII/Programming/Amira Writer` as the canonical home for the unified Opera app.
- This directory is the Swift/native Amira Writer workspace only.
- Do not add Electron, React, Node, Docker, Flynn web-conversion, or Amira Writer Web implementation files here.
- The Electron/server conversion lives separately at `/Volumes/Storage VIII/Programming/Amira Writer Web`.
- If a request is about the web/Electron/server conversion, switch to `/Volumes/Storage VIII/Programming/Amira Writer Web` instead of editing this Swift workspace.
- The web project may read this Swift workspace as a parity reference, but this Swift workspace should not depend on or import anything from the web project.
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

## App Control Permission Boundary

- Agents are allowed to launch, quit, relaunch, and otherwise control the Amira Writer/Opera application **on Garys-Server** when needed for builds, validation, API availability, or server-side testing.
- Agents are **not** allowed to launch, quit, relaunch, kill, or otherwise control applications on **Garys-Laptop** unless Gary explicitly approves that action in the current session.
- If Gary is testing from the laptop, treat the laptop app as user-controlled; update the server-side bundle and ask Gary to relaunch or test the synced copy himself.

## Handoff Docs

- Start with `README.md`.
- Then read:
  - `history/HANDOFF-2026-03-21-UI-SIMPLIFICATION.md`
  - `history/HANDOFF-2026-03-21.md`
  - `history/OPERA-CONSOLIDATION-2026-03-21.md`
  - `history/OPERA-DEVELOPMENT-HISTORY-2026-03-21.md`

## Codebase Professionalization (Completed 2026-05-25)

**Canonical spec:** `docs/specs/2026-05-25-codebase-professionalization-plan.md`
**Handoff:** `history/HANDOFF-2026-05-25-CODEBASE-PROFESSIONALIZATION.md`

All 5 phases are complete:
- **Phase 0:** ProjectKit utilities (DateFormatters, StringExtensions, AmiraLogger, ColorHex)
- **Phase 1:** MIDIPlaybackEngine split into 4 sub-engines in `Stores/Audio/`
- **Phase 2:** Directory reorg — 214 files moved from flat `Services/`/`Views/` into topic subdirectories
- **Phase 3:** MARK sections added to 5 largest view files
- **Phase 4A/4B:** ScoreStore → 5 sub-stores, AnimateStore → 9 sub-stores
- **Phase 5:** `.swiftlint.yml` added, bridges renamed (Write/Score/AnimateProjectBridge), build clean

**Extraction pattern for new stores:**
- `@MainActor final class FooStore { unowned let parent: ParentClass; init(parent:) ... }`
- Parent: `@ObservationIgnored private var _foo: FooStore?` + lazy computed `var foo: FooStore`
- Facade: `func method() { foo.method() }` (one-line delegation)
- Build is clean — 0 errors as of 2026-05-25

## Programmatic Interfaces (API)

**Canonical doc:** `docs/API.md` — HTTP JSON API on `localhost:19847`, active once the app is open and on the Score page. Use this for WAV export (`/export/full-mix`), song/note/tempo/playback/mixer/version operations (~60 endpoints).

Do **not** use `Scripts/export-headless-wav.sh` or the `Score` package binary — they produce sine tones, not real audio.

The env-var headless full-mix export path (`AMIRA_HEADLESS_FULLMIX_EXPORT`) is **not** a supported agent workflow: it was documented once and retired because it did not work reliably end-to-end from an agent context. If you need a WAV headlessly, drive the open app via the HTTP API.

## Write Page Card Timeline

- For scratchpad-to-libretto/card conversion, follow `docs/specs/2026-04-29-write-page-card-authoring-contract.md`.
- Do not target the old side-lane script-card workflow for new Write page shot/action/lyric work.
- The visible Write page is a card timeline: story/lyrics/action on the left, shot/camera/direction/notes on the right, with `.ows` lyrics bracket markup as the hidden compatibility layer.
