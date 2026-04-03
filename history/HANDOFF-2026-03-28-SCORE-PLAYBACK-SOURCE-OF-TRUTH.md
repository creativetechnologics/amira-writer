# Score Playback Source-of-Truth Tightening

Date: 2026-03-28

## Goal

Make the score page prefer on-disk `.ows` playback truth for the selected song, add an explicit reload path, and stop stale in-memory/cache playback from masking valid moved music.

## Files Changed

- `Packages/Score/Sources/ScoreUI/ScoreStore.swift`
- `Packages/Score/Sources/ScoreUI/Views/PianoRollToolbarView.swift`
- `Packages/Score/Tests/ScoreTests/ScoreStoreExternalWatchTests.swift`
- `Packages/Score/Tests/ScoreTests/OWSSongDocumentTests.swift`

## Behavioral Changes

1. Selected-song score hydration now prefers the source `.ows` file when playback is requested.
2. The score loader now treats `playbackSnapshot` as equivalent to `playback` when decoding an `.ows`.
3. Saving an active version writes both `playback` and `playbackSnapshot` for compatibility.
4. The overflow menu now includes `Reload Song From Source`.
5. Reload from source is intentionally blocked when the selected song has unsaved local changes.
   This is a safety guard to avoid clobbering visible front-end work.
6. When the selected song has empty or missing playback and is not dirty, the store makes one source-truth recovery attempt instead of trusting the stale in-memory/cache copy forever.

## What Did Not Change

- No song data was migrated or deleted.
- Legacy `music` blobs were not rewritten or removed.
- SQLite schema was not changed.
- The project cache still exists, but the selected score view no longer treats it as authoritative playback truth.

## Rationale

- Canonical score data for the score page should be `activeVersion.playback` from the `.ows` file.
- The project database remains a derived index/cache for project summaries and change tracking.
- Dirty selected songs are not auto-reloaded from source because that can destroy unsaved visible work.

## Rollback

Revert the four files listed above.

If the behavioral shift causes issues, the lowest-risk rollback is:

1. Remove `reloadSelectedSongFromSource(...)` and the toolbar button.
2. Restore `hydrateSongDetailsIfNeeded(...)` to prefer database playback for selected-song hydration.
3. Restore `loadSelectedMidiIfPossible()` so it only retries hydration when playback is `nil`.

## Verification Targets

- Selecting a song with valid on-disk playback should populate the score even if cached playback is stale/empty.
- `Reload Song From Source` should refresh the selected song without reopening the project.
- If the selected song has unsaved edits, reload should refuse and preserve front-end state.
