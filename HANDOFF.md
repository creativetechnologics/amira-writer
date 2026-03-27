# Amira Writer — Code Review Handoff
**Date:** 2026-03-22 06:04 UTC
**Performed by:** Claude Opus 4.6 (review) + Claude Sonnet 4.6 (implementation)
**Prior session:** Anti-Gravity UI cleanup pass

---

## What Was Done

A full code audit was performed across all four packages:
- `Sources/NovotroWrite`
- `Sources/NovotroOpera`
- `Packages/NovotroScore`
- `Packages/NovotroAnimate`
- `Packages/NovotroProjectKit`

The following bugs were found and fixed.

---

## Fixes Applied

### Fix 1 — Database sync polling silently dies on error
**Severity:** Critical
**Files changed:**
- `Sources/NovotroWrite/ScriptStore.swift` — `pollDatabaseChanges()` and `applyDatabaseChange(_:)` (5 Task blocks)
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift` — `pollDatabaseChanges()` and `applyDatabaseChange(_:)` (2 Task blocks)
- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift` — `pollDatabaseChanges()` and `applyDatabaseChange(_:)` (7 Task blocks)

**Problem:** Every `Task { try await ... }` block in the database polling and change-application code had bare `try` with no error handling. Any thrown error (DB locked, file missing, connection dropped) would silently kill the task — permanently stopping sync for that session with no log entry and no recovery.

**Fix:** Wrapped every `try` inside `do { } catch { NSLog("[StoreN] ...", error.localizedDescription) }`.

---

### Fix 2 — `.novtro` directory typo
**Severity:** Critical
**File:** `Packages/NovotroProjectKit/Sources/NovotroProjectKit/NovotroProjectDatabase.swift` line 14

**Problem:** The default database directory was `.novtro` (missing the second `o`). If callers relied on the default `databaseDirectoryURL`, the SQLite index would be created in the wrong folder.

**Fix:** Changed `.novtro` → `.novotro`. The SQLite database is a rebuilable index; any existing `.novtro` databases will be transparently recreated from the `.ows` files on next open.

---

### Fix 3 — AgentProcessManager: readability handler nulling races with main thread
**Severity:** High
**File:** `Sources/NovotroWrite/Services/AgentProcessManager.swift`

**Problem:** `process.terminationHandler` fired on a background thread and set `stdoutHandle.readabilityHandler = nil` and `stderrHandle.readabilityHandler = nil` before dispatching to the main queue. This raced with the GCD readability dispatch on the main thread.

**Fix:** Moved both `readabilityHandler = nil` assignments inside the `DispatchQueue.main.async` block, ordered before the `onComplete` call.

---

### Fix 4 — ConsoleProjectSync: redundant FD tracking array
**Severity:** Low (dead code / clarity)
**File:** `Sources/NovotroWrite/Services/ConsoleProjectSync.swift`

**Problem:** `watcherFileDescriptors: [Int32]` was populated in `startWatching()` and then immediately cleared in `stopWatching()` — before the DispatchSource cancel handlers had a chance to fire and close the FDs. The array was redundant because each cancel handler already captures and closes its own `fd` by value. The array served no purpose.

**Fix:** Removed the `watcherFileDescriptors` property entirely. FD lifecycle is handled correctly by the cancel handlers.

---

### Fix 5 — Gemini API key exposed in URL query parameter
**Severity:** High (security)
**File:** `Packages/NovotroAnimate/Sources/NovotroAnimate/Services/GeminiImageService.swift`

**Problem:** The Gemini API key was appended to the URL as `?key=<apiKey>`. This exposes the key in URLSession debug logs, crash reports, and proxy traffic. The URL construction also used a force-unwrap `URL(...)!`.

**Fix:**
1. Removed `?key=\(apiKey)` from the URL string.
2. Changed `URL(string:)!` to `guard let url = URL(string:) else { throw ServiceError.invalidResponse }`.
3. Added `urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")` — the standard Gemini header.

---

### Fix 6 — MFCCSimilarity crashes on zero-length audio
**Severity:** High
**File:** `Packages/NovotroScore/Sources/NovotroScore/Services/MFCCSimilarity.swift`

**Problem:** `fftMagnitude(_:)` used `baseAddress!` on `UnsafeMutableBufferPointer` initialized from arrays of length `n/2`. If `n == 0`, those arrays are empty and `baseAddress` is `nil`, causing a crash.

**Fix:** Added `guard n > 0 else { return [] }` at the top of the function.

---

### Fix 7 — NovotroProjectAsyncTimeout: zero-second timeout fires immediately
**Severity:** High
**File:** `Packages/NovotroProjectKit/Sources/NovotroProjectKit/NovotroProjectAsyncTimeout.swift`

**Problem:** When `seconds == 0`, `timeoutNanoseconds` was `0`, so `Task.sleep` was skipped and the timeout task threw `operationTimedOut` before the operation task could even execute. Any call with `seconds: 0` would always fail.

**Fix:** Added `guard seconds > 0 else { return try await operation() }` at the top. Zero or negative seconds now runs the operation directly with no timeout racing against it. Also simplified the internal logic by removing the now-unnecessary `if timeoutNanoseconds > 0` branch.

---

### Fix 8 — OperaChromeDivider `opacity` parameter never applied
**Severity:** Medium
**File:** `Packages/NovotroProjectKit/Sources/NovotroProjectKit/OperaChrome.swift`

**Problem:** `OperaChromeDivider` accepted an `opacity: Double` parameter and stored it, but the `body` property never applied `.opacity(opacity)` to either divider variant. Passing any opacity value had no effect.

**Fix:** Added `.opacity(opacity)` to both the vertical (`Divider().frame(width: 1)`) and horizontal (`Divider()`) variants in `body`.

---

### Fix 9 — `toTitleCase()` mangles Roman numerals and acronyms
**Severity:** Medium
**File:** `Sources/NovotroWrite/ScriptStore.swift`

**Problem:** The `toTitleCase()` extension always lowercased everything after the first character. `"Act II"` → `"Act Ii"`, `"Part III"` → `"Part Iii"`.

**Fix:** Added a guard before the capitalize-then-lowercase step: if a word is all letters, all uppercase, and longer than one character, it's preserved as-is. Single uppercase letters (e.g. `"A"`) still get title-cased normally.

---

## Intentionally Not Changed

The following were flagged during review but confirmed to be intentional design:

| Item | Reason left as-is |
|------|-------------------|
| `autoSaveEnabled` always writes `false` to UserDefaults; `scheduleAutoSaveIfNeeded()` is a no-op | **Intentional.** Auto-save is permanently disabled to prevent the app from overwriting files that LLM agents are actively editing. |
| `NovotroProjectDatabase` `deinit` calls `sqlite3_close` nonisolated | Safe in Swift 6: `deinit` runs only after ref count reaches zero, so no concurrent actor-isolated calls can be in flight. |
| `AgentProcessManager.resolveExecutablePath()` calls `waitUntilExit()` on MainActor | Caching in `fullShellPath()` means the blocking call only fires once. `resolveExecutablePath()` checks `FileManager.isExecutableFile` (fast) first; shell fallbacks only occur on the very first miss. Refactoring risks breaking agent process launching. |
| `ScriptStore.save()` silently no-ops if a save is already in-flight | Intentional: `dirtySongPaths` is cleared before the Task at line 1006; new edits during save re-dirty by adding to the set directly; `isSaving = false` unblocks the next manual Cmd+S. |
| `NovotroProjectMirrorSession` has no `shutdown()` | Mirror/remote mode is disabled — the Novotro Project Server is abandoned and never used. |

---

## Build Verification Needed

Before deploying, run:
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
swift build -c release 2>&1 | tail -20
```

Key areas to manually test:
- Open any project → switch between Write / Score / Animate (Cmd+1/2/3)
- Have an external agent edit a `.ows` file → verify the glow update and reload
- Use the Console agent panel → verify agent runs and output streams correctly
- In Animate, trigger image generation → verify it doesn't crash and the API call succeeds
