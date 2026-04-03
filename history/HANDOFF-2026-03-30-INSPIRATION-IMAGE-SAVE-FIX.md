# Inspiration Image Generation Save Fix

**Date:** 2026-03-30
**Status:** Fixed and verified

## Problem

Inspiration images generated via the Gemini API for characters in Animate > Characters were being written to disk successfully but never appearing in the gallery. The images "disappeared" — they were on disk but not tracked in the character's `inspirationImagePaths` array in `rig.json`.

The bug was character-agnostic but appeared most visibly on characters like Yasmin Nazari who had `owpSlug: "new-character"` (not in the OWP characters.json manifest), because those characters had no other mechanism to recover the paths.

## Root Cause

**`save()` was silently bailing out due to a race condition with `checkForExternalProjectChanges()`.**

In `AnimateStore.save()`:

```swift
func save() {
    checkForExternalProjectChanges()          // (1) detects file changes
    guard !isAgentSyncInProgress else {        // (2) checks flag
        return  // BAIL — paths never written to disk
    }
    // ... write rig.json ...
}
```

The sequence:
1. `save()` calls `checkForExternalProjectChanges()` at the top
2. If any monitored file changed (e.g., `animate.json` from a previous save), `handleExternalProjectFileChange` is called
3. `handleExternalProjectFileChange` immediately calls `beginAgentSync()` which sets `isAgentSyncInProgress = true`
4. It then starts an **async** `Task` to process the change (which would eventually call `markAgentUpdated()` to clear the flag)
5. Back in `save()`, the guard checks `isAgentSyncInProgress` — it's `true` (the async task hasn't completed yet)
6. `save()` bails with "Detected newer agent changes" status message
7. The inspiration image path that was just added to in-memory state is **never written to `rig.json`**

The path lived only in memory until the next `syncCharactersFromOWP` reloaded the character from disk (without the path), silently discarding it.

## Fix

In `AnimateStore.save()`, capture the sync state **before** calling `checkForExternalProjectChanges()`. Only bail if a sync was already in progress from a *previous* operation — not one that was just triggered by the check itself:

```swift
func save() {
    let wasSyncingBeforeCheck = isAgentSyncInProgress
    checkForExternalProjectChanges()
    guard !wasSyncingBeforeCheck, !hasPendingAgentChanges else {
        return
    }
    // ... write rig.json ...
}
```

This preserves the safety behavior (don't overwrite data from an in-flight external sync) while fixing the self-blocking race.

## Additional Repairs

- Manually repaired `yasmin-nazari/rig.json` to include 6 inspiration image paths that had been generated but never persisted
- Added temporary file-based diagnostic logging to `storeGeneratedInspirationImage`, `save()`, and `normalizedCharacterAssetPaths` (writes to `/tmp/amira-inspiration-debug.log`) — these should be removed once the fix is confirmed stable

## Files Changed

- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift` — save() race condition fix + diagnostic logging

## Verification

Confirmed via diagnostic log that:
- Before fix: `save() BAILED: agentSync=true` every time
- After fix: `save() complete, final count: N` — saves succeed, images appear in gallery

## Batch Generation

The batch generation pathway (`gemini_inspiration_batch.py`) was verified:
- Python script syntax is valid
- `google-genai` package is installed in the vendor directory
- The `GeminiBatchService` Swift class correctly invokes the script
- Batch results would have suffered the same `save()` bail issue (now fixed)
