# Handoff: Save Indicators, Synopsis Redesign & Bug Fixes
**Date:** 2026-03-23
**Time:** ~16:55 PST
**Branch:** main

---

## Summary

This session delivered three user-facing UI changes and three critical bug fixes surfaced by a code review agent.

---

## UI Changes

### 1. Save Indicator Moved to Shell Tab Bar

**What changed:**
- The "Saving..." / "Saved ✓" indicator now lives in the global Novotro Opera tab bar, immediately to the right of the "Novotro Opera" title text.
- This is consistent across all three modes: Write, Score, and Animate.
- The status bar in Write no longer shows the save state (it still shows status messages, dirty dot, and scene count).

**Files changed:**
- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/OperaChrome.swift` — Added shared `SaveIndicatorState` enum (public) and `OperaChromeCompactSaveIndicator` view
- `Sources/NovotroOpera/OperaShellView.swift` — Added `activeSaveIndicator` computed property + indicator in `tabBar`
- `Sources/NovotroWrite/Views/ContentView.swift` — Removed save state from `OperaChromeStatusBar` call
- `Sources/NovotroWrite/ScriptStore.swift` — Removed local `SaveIndicatorState` enum (now shared)
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift` — Removed local `SaveIndicatorState` enum (now shared)
- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift` — Added `saveIndicator` property + save state tracking in `save()` function (was missing entirely)
- All 3 workspace controllers — Added `public var saveIndicator: SaveIndicatorState` computed property forwarding from store

**Why:** Gary reported that pressing save felt like "nothing was happening." By putting the indicator in the top bar (always visible), it's impossible to miss.

---

### 2. Traffic Light Button Alignment

**What changed:**
- Added `.padding(.top, 4)` to the tab bar in `OperaShellView`. This pushes the "Novotro Opera" text and mode buttons down 4px so they visually align with the macOS close/minimize/zoom (traffic light) buttons.

**Files changed:**
- `Sources/NovotroOpera/OperaShellView.swift`

**Why:** The traffic lights were slightly above the title text, which looked misaligned.

---

### 3. Synopsis Redesign — Per-Scene Embedded Paragraphs

**What changed:**
The entire synopsis system was redesigned from a single shared file to per-scene embedded blocks.

**Old behavior:**
- Synopsis stored in `Synopsis/synopsis.txt` with `{{{SCENE:Songs/filename.ows}}}` markers
- The inspector showed a flat scrollable list with all scenes, not auto-synced to current scene

**New behavior:**
- Each scene's synopsis paragraph is stored directly inside its libretto `.ows` file as a hidden block:
  ```
  {{{SYNOPSIS}}}
  This is the synopsis paragraph for this scene.
  {{{/SYNOPSIS}}}
  ```
- The synopsis block is stripped from the editor display — users never see the raw tags
- The inspector Synopsis tab shows all scenes listed with their synopses
- The active scene (whatever you're editing/scrolling through) is highlighted with an accent color left border and auto-scrolled to
- Each scene row has an inline pencil edit button for its synopsis
- Old `Synopsis/synopsis.txt` data is **auto-migrated** on first project load — existing content is parsed and embedded into the correct libretto files, no manual action needed

**Files changed:**
- `Sources/NovotroWrite/Views/SynopsisSectionView.swift` — Complete rewrite; added `SynopsisEmbedding` utility + `LegacySynopsisParser` for migration
- `Sources/NovotroWrite/ScriptStore.swift` — Added `synopsis(forScenePath:)`, `updateSynopsis(forScenePath:text:)`, `migrateLegacySynopsisIfNeeded()`
- `Sources/NovotroWrite/Views/ScriptCenterView.swift` — Editor now strips synopsis blocks for display and re-embeds them when writing back (all sync paths updated)
- `Tests/NovotroWriteTests/ScriptStoreTests.swift` — Updated test references from removed `SynopsisScenePathResolver` to `LegacySynopsisParser`

---

## Bug Fixes (from code review agent)

### Bug 1 — Background Watchers Not Restarting After Mode Switch (Critical)

**Problem:** When switching modes (e.g., Write → Score → Write), `suspendBackgroundWork()` stopped all file/database watchers. On re-entry, `ensureProjectLoaded` short-circuited at the fast path without restarting them. After one round-trip, external file changes and agent sync events were silently ignored for the rest of the session.

**Fix:** Added `resumeBackgroundWork()` to all 3 stores (`startFileWatching()` + `startDatabaseWatch()`) and to all 3 workspace controllers. The fast-path return in `ensureProjectLoaded` now calls it before returning.

**Files:** All 3 stores + all 3 workspace controllers.

---

### Bug 2 — Rapid Mode-Switch Race Condition (Important)

**Problem:** Rapidly tapping mode tabs spawned multiple concurrent `handleModeSelectionChange` tasks that raced on `renderedMode` and `loadState`. The final rendered mode was determined by whichever async task finished last, not which tab the user tapped last.

**Fix:** Added `@State private var modeSwitchTask: Task<Void, Never>?` to `OperaShellView`. Each new mode selection cancels the previous task. Added `Task.isCancelled` checks at critical commit points inside `handleModeSelectionChange`.

**Files:** `Sources/NovotroOpera/OperaShellView.swift`

---

### Bug 3 — Scratchpad-Only Save Reentrancy (Important)

**Problem:** When only the scratchpad was dirty, `ScriptStore.save()` executed the scratchpad path without setting `isSaving = true`, allowing re-entrant calls from rapid Cmd+S to double-invoke the save and schedule two competing timer callbacks.

**Fix:** Added `isSaving = true` / `isSaving = false` around `saveScratchpad()` in the scratchpad-only branch.

**Files:** `Sources/NovotroWrite/ScriptStore.swift`

---

## Build Status

- **Xcode build:** SUCCEEDED (scheme NovotroOpera)
- **Tests:** All 17 tests passed (NovotroWriteTests)

---

## Known Non-Issues (confirmed safe by review)

- `OperaWindowAccessor.applyBurst` pattern — intentional, safe
- `handleModeSelectionChange` revert loop on load failure — caught by `guard newMode != renderedMode`
- Synopsis edit-cancel behavior — discards `editText` silently, store remains consistent

---

## Next Steps / Open Items

- The `CADisplayLink` in AnimateStore is never invalidated after playback starts (low priority: no store leak, but a stale run-loop entry). Could add `displayLink.invalidate()` in `suspendBackgroundWork()`.
- `openProjectFromDisk` is missing explicit `@MainActor` annotation (low risk: works correctly in practice, but fragile if refactored).
