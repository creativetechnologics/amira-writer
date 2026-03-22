# Opera Development History

## Summary Timeline

1. `Novotro Write`, `Novotro Score`, and `Novotro Animate` were previously split into separate apps.
2. `Novotro Opera` was reintroduced as a unified shell that hosts all three modes.
3. Early attempts only wrapped the old apps and did not fully migrate the experience, which caused UI mismatch and mode/session bugs.
4. The shell was then refactored toward a shared-project model, closer to the older Claude PM-style chrome.
5. Shared Opera chrome, inspector work, and sidebar consistency passes were added.
6. A Write scratchpad column was added so staged libretto edits can exist before an LLM commits them to the script.
7. A local mirror sync system was introduced so projects open from a cached local copy instead of streaming directly from the server.
8. Loading progress UI was added for first-open and sync phases.
9. Multiple fixes landed in the project browser and project server discovery path, including endpoint fallback, timeout handling, and retry logic.

## Important Functional Changes

- One project session is shared across Write, Score, and Animate.
- Project selection is intended to live at the Opera layer instead of per-mode subapps.
- The right-side inspector work moved away from accordion-heavy behavior toward more tabbed/shared chrome.
- Score and Animate internals are still feature-rich, but now live inside a unified Opera shell.

## Known Risk Areas

- Project server discovery and browser behavior on Gary's laptop
- Initial project open / mirror hydration timing for very large projects such as `Amira`
- Remaining visual inconsistencies inside deeper mode-specific controls

## Best Files To Read First

- `Sources/NovotroOpera/OperaShellView.swift`
- `Sources/NovotroOpera/NovotroOperaApp.swift`
- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/OperaChrome.swift`
- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/NovotroProjectMirrorSync.swift`
- `Packages/NovotroProjectKit/Sources/NovotroProjectKit/NovotroProjectServerBrowser.swift`
- `Sources/NovotroWrite/ScriptStore.swift`
- `Packages/NovotroScore/Sources/NovotroScore/NovotroScoreWorkspace.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/NovotroAnimateWorkspace.swift`
