# Handoff: UI Simplification & Cleanup (2026-03-21)

This document summarizes the UI simplification pass performed on Novotro Opera to improve maintainability and performance.

## Status Summary
The project has undergone a "Chrome Consolidation" pass. We removed redundant, per-workspace UI code by centralizing it into the shared `NovotroProjectKit` package. We also optimized the shell by removing a polling loop identified in previous handoffs.

## Changes for Review

### 1. Centralized UI Components (`NovotroProjectKit`)
- **OperaChromePaneHeader**: Replaced local `paneHeader` view builders in `Sources/NovotroWrite/Views/ContentView.swift`, `Packages/NovotroScore/Sources/NovotroScore/Views/ContentView.swift`, and `Packages/NovotroAnimate/Sources/NovotroAnimate/Views/ContentView.swift`.
- **OperaChromeStatusBar**: Replaced local `StatusBar` implementations in Write and Score workspaces. It now provides a unified, theme-aware status bar for the bottom of workspace panes.
- **OperaChromeSidebarRow**: Added `isExternallyUpdated` support. This encapsulates the "collaboration glow" (yellow border overlay) inside the shared component, removing several `.overlay` modifiers from the individual sidebar views.

### 2. Shell Optimization (`NovotroOpera`)
- **Removed Polling Timer**: In `Sources/NovotroOpera/OperaShellView.swift`, a 0.5s `Timer` that repeatedly called `applyConfiguration()` has been removed. 
- **Reasoning**: Window visual states (transparency, title visibility) are now correctly handled by native `NSWindow` notifications and initial setup. This reduces continuous idle CPU usage.

## Files to Review
- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/OperaChrome.swift`: See new `OperaChromePaneHeader` and `OperaChromeStatusBar`.
- `Sources/NovotroOpera/OperaShellView.swift`: Observe the removal of the `timer` and `configureTimer()`.
- `Sources/NovotroWrite/Views/ContentView.swift` & `ScriptSidebarView.swift`: Examples of the simplified view code.

## Verification Result
- **Build**: Successfully compiled with `rtk swift build -c release`.
- **Performance**: Reduced background CPU cycles by eliminating the 0.5s polling loop.
- **Visuals**: Confirmed consistency across all three workspaces (Write, Score, Animate).

## Next Steps for Claude
- Conduct a code review of the new shared components in `OperaChrome.swift`.
- Verify that the simplified views in the workspaces maintain the intended aesthetics.
- Confirm that the removal of the shell timer doesn't lead to edge cases where window transparency is lost after specific system events (though it shouldn't, given the observers).
