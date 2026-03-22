# Novotro Opera Handoff — Anti-Gravity UI Cleanup

## Purpose

This handoff is for a focused UI cleanup and optimization pass in `Novotro Opera`.

The current app state already includes:

- compacted shared sidebars across `Write`, `Score`, and `Animate`
- a narrower, better-padded loading overlay
- fast-open project loading with lightweight summaries and background hydration
- disk-first song membership/order on open, so stale local DB summaries cannot show deleted or reordered songs
- real-time external-disk update syncing intended for LLM/agent collaboration
- manual-save protection so local saves do not overwrite newer external agent changes

The next agent should treat this as a polish and cleanup pass, not a ground-up redesign.

## Canonical Root

- Canonical workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`
- App target: `NovotroOpera`
- App bundle: `/Volumes/Storage VIII/Users/gary/Applications/Novotro Opera.app`
- Laptop deploy target: `gary@Garys-Laptop.local:~/Applications/Novotro Opera.app`

## Current Shipped State

As of March 21, 2026:

- `swift build -c release` passed
- `Scripts/build-app.sh` completed successfully
- `Novotro Opera.app` was deployed to `gary@Garys-Laptop.local:~/Applications/`

## Important Behavior To Preserve

- Do not re-enable autosave for this collaboration workflow.
- External disk changes should appear in-app quickly without requiring a restart.
- If newer agent changes are detected before a manual save, the app should refuse the save and reload those changes first.
- The shared compact sidebar feel should remain aligned across `Write`, `Score`, and `Animate`.
- The fast-open path should remain lightweight and should not regress back to blocking on a full cold rebuild before the user can work.
- The local DB index is a cache, not the source of truth for which songs/scenes exist. Disk should continue to own membership and order.

## Most Relevant Files

### Shared Chrome And Layout

- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/OperaChrome.swift`
- `Sources/NovotroWrite/Views/ContentView.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Views/ContentView.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/ContentView.swift`

### Sidebar Density / Row UI

- `Sources/NovotroWrite/Views/ScriptSidebarView.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Views/ContentView.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/SidebarView.swift`

### Fast Open / Background Hydration

- `Sources/NovotroWrite/Services/ProjectDatabaseBridge.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Services/ProjectDatabaseBridge.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Services/ProjectDatabaseBridge.swift`
- `Sources/NovotroWrite/ScriptStore.swift`
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift`

### Loading Overlay / Shell

- `Sources/NovotroOpera/OperaShellView.swift`

## Collaboration Sync Behavior Already Added

### Write

- top-bar collaboration badge
- sidebar row glow for recently externally updated scenes
- external disk reloads for scenes, synopsis, and scratchpad
- DB sync after external reload so mode switching stays coherent

Primary files:

- `Sources/NovotroWrite/ScriptStore.swift`
- `Sources/NovotroWrite/Views/ContentView.swift`
- `Sources/NovotroWrite/Views/ScriptSidebarView.swift`

### Score

- top-bar collaboration badge
- sidebar row glow for recently externally updated songs
- periodic external file watch for `.ows` files and project metadata
- manual-save guard when newer external agent changes are waiting
- background index refresh that reloads only when safe

Primary files:

- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Views/ContentView.swift`

### Animate

- top-bar collaboration badge
- sidebar row glow for recently externally updated scenes
- external file watch for `.ows`, `Animate/scenes.json`, `Animate/animate.json`, shot presets, package selections, `characters.json`, and `index.json`
- manual-save guard when newer external agent changes are waiting
- project rescan path when song membership changes on disk

Primary files:

- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/ContentView.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/SidebarView.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Services/ProjectDatabaseBridge.swift`

## Recommended Scope For Anti-Gravity

Focus on cleanup and UI/UX optimization in this order:

1. Refine visual density and spacing consistency across all three workspaces.
2. Improve perceived responsiveness of large-project views while preserving current behavior.
3. Polish the collaboration indicator and recent-update highlighting so it feels intentional and elegant.
4. Review top-bar, sidebar, and inspector chrome for repeated patterns that can be simplified.
5. Avoid changing project persistence rules unless a UI issue truly requires it.

## Good Next Audit Targets

- `Sources/NovotroOpera/OperaShellView.swift`
  - there is still a 0.5s shell-level polling path worth auditing for performance impact
- `Sources/NovotroWrite/Views/ScriptCenterView.swift`
  - verify large-libretto rendering remains smooth after the lazy-stack conversion
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
  - review external watch cadence and whether some reload work can be further narrowed
- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift`
  - review the new external change handling for any extra reload work that can be deferred

## Constraints

- Stay inside the unified Opera workspace only.
- Do not move new work back into legacy sibling repos.
- Do not remove the collaboration protections unless explicitly requested.
- Rebuild and redeploy after app changes.

## Build And Deploy

Use the repo-standard flow:

```bash
rtk swift build -c release
rtk /Volumes/Storage VIII/Programming/Novotro Opera/Scripts/build-app.sh
rtk scp -r "$HOME/Applications/Novotro Opera.app" gary@Garys-Laptop.local:~/Applications/
```

## How To Hand Back To Codex

When returning to this agent, provide:

- this file: `history/HANDOFF-2026-03-21-ANTIGRAVITY-UI.md`
- the main workspace handoff: `history/HANDOFF-2026-03-21.md`
- a short note describing what Anti-Gravity changed, especially any UI chrome, spacing, or performance-related behavior changes

That should be enough to resume without re-discovering the current collaboration/loading architecture from scratch.
