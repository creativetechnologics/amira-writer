# Amira Writer Handoff — Suno Cover Bulk Debug (2026-04-21)

## Goal
Pause-point handoff for the Suno cover workflow investigation in Amira Writer, including single-song validation, Mix-page verification, and the in-progress bulk-cover fix.

## What Was Verified Before This Pause

### 1) Cover outputs attach to the correct song on the Mix page
I previously verified that downloaded Suno WAVs are being registered under the correct song session in:
- `/Users/gary/Amira - A Modern Opera/Metadata/mix_session.json`

Specifically, for:
- `Songs/1.01.0 - Overture.ows`

I confirmed that the Overture Suno WAVs were present under:
- `.sceneSessions["Songs/1.01.0 - Overture.ows"].clips`

I also opened the Mix page in the running app and confirmed it loaded and reflected the Overture clip count instead of staying blank.

### 2) Negative prompt hyphen issue
I checked the current app-side code and did **not** find any current code path that prepends `-` to each negative prompt entry.

Confirmed relevant paths:
- `/Volumes/Programming/Amira Writer/Packages/Score/Sources/ScoreUI/ScoreStore.swift`
  - `normalizedSunoExcludeStyles()` strips leading dashes rather than adding them.
- `/Volumes/Programming/Amira Writer/Packages/Score/Sources/ScoreUI/Services/SunoCLIRunner.swift`
  - forwards the normalized negative prompt to the CLI without adding hyphens.

The visible UI field also currently showed:
- `piano, percussion, drums, beat`

not dashed list items.

### 3) Bulk cover behavior before the patch
Before this pause, I had already validated a real bulk-cover queue setup in the app:
- Selected songs:
  - `1.01.0 - Overture`
  - `1.02.0 - Prologue`
  - `1.05.0 - Silver`
- Queue summary showed:
  - `1 cycles × 3 songs → 3 submits / about 6 outputs`

Observed behavior before the patch:
- `1.01.0 Overture v023` succeeded and downloaded both WAVs.
- The queue then entered a real randomized cooldown (`Queue cooldown: waiting 9m 58s...`).
- The second queued song, `1.02.0 Prologue v001`, failed during upload with a file-input selector issue.

That failure was:
- `Locator.set_input_files: Timeout 10000ms exceeded`
- waiting on:
  - `locator("input[type=file][accept*=\"audio\"]").nth(1)`

## Root Cause Found
The Suno CLI upload path was choosing the wrong file input when Suno rendered multiple audio-related `<input type="file">` elements.

Problem file:
- `/Volumes/Programming/SunoSkill/suno_cli/src/suno_cli/core/tools/basic/tools.py`

Problem area:
- `_resolve_file_input_locator(...)`
- `upload_audio(...)`

The old logic effectively trusted a single candidate and could land on the wrong/stale input during the bulk cover flow.

## Patch Applied
I patched:
- `/Volumes/Programming/SunoSkill/suno_cli/src/suno_cli/core/tools/basic/tools.py`

### What changed
1. Added ordered candidate scoring for matching file inputs.
2. Added `_set_input_files_with_fallback(...)` to try all plausible matching file inputs instead of trusting one brittle locator.
3. Updated `upload_file(...)` to use the fallback uploader.
4. Updated `upload_audio(...)` to:
   - wait for the audio-specific file input first,
   - only fall back to generic `input[type=file]` if needed,
   - then use the multi-candidate fallback uploader.

## Validation After Patch

### Build / deploy
I rebuilt on Gary's server with:
- remote build tool against:
  - `/Volumes/Storage VIII/Programming/Amira Writer`

Server-side deployed bundle timestamp reported by the build step:
- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
- modified around:
  - `2026-04-21 14:44 PDT`

Local notes:
- The synced local copy at:
  - `/Users/gary/Programming/!Applications/Amira Writer.app`
  was still old (`2026-04-19 17:37:38 PDT`) when checked.
- For testing, I therefore relaunched the app directly from the mounted up-to-date bundle:
  - `/Volumes/Programming/!Applications/Amira Writer.app`

### Current app instance during this handoff
Relaunched app path:
- `/Volumes/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera`

Observed app PID during this session:
- `98482`

### Single-song re-test after the upload patch
After relaunch, I reopened Score → Suno → Cover and set Source to:
- `Current Song`

Current active song:
- `1.01.0 - Overture`

I then started a new real cover run through the app/API:
- `1.01.0 Overture v024`

### Important result
The new patched run **got past the previous upload blocker**.

As of the last status check before this pause, the run had progressed to:
- `status: downloading`

and had already captured both Suno song IDs:
- `41cc4773-24de-4cfc-9a2a-b04cc9d0f37a`
- `091e0cd6-665e-4a5c-b990-6729f4df6cdf`

Latest status snapshot at pause time:
```json
{
  "latest": {
    "coverTitle": "1.01.0 Overture v024",
    "status": "downloading",
    "songIDs": [
      "41cc4773-24de-4cfc-9a2a-b04cc9d0f37a",
      "091e0cd6-665e-4a5c-b990-6729f4df6cdf"
    ],
    "downloadedFilePaths": [],
    "errorMessage": null
  }
}
```

This is materially better than the previous failure mode:
- previous failure: upload/input selection broke on Prologue
- current state: upload succeeds, IDs are captured, workflow is now waiting on WAV downloads

## Current Testing State At Pause

### Confirmed working before pause
- Overture covers can be submitted from the app.
- Previous Overture runs attached into the correct Mix session.
- The bulk queue did real 5–10 minute cooldown spacing.
- The upload-selector bug that broke `1.02.0 Prologue v001` has been patched.
- The fresh post-patch run `1.01.0 Overture v024` has already advanced to **downloading** with two captured song IDs.

### Not yet fully re-verified after the patch
These are still pending after the pause request:
1. Final completion of `1.01.0 Overture v024` download back into the project folder.
2. Confirming the new `v024` WAVs appear in the Overture Mix session.
3. Re-running the 3-song bulk-cover test after the upload patch to prove:
   - Overture
   - Prologue
   - Silver
   all run through the cover queue correctly.

## Helpful Runtime Clues From This Session

### Live CLI process observed during the current test
A real visible Suno CLI process was running from the bundled app resources:
- `/Volumes/Programming/!Applications/Amira Writer.app/Contents/Resources/SunoCLI/suno_cli/.venv/bin/suno`

Observed command shape:
- `generate cover`
- `--source /Users/gary/Amira - A Modern Opera/Mix/exports/1_01_0_-_Overture.wav`
- `--visible`
- `--wait`

### CDP / browser observation
The shared persistent Chrome session was reachable on a remote debugging port and showed active Suno pages under:
- `https://suno.com/create`
- `https://suno.com/me/history`

That confirmed the visible-browser path was alive during the new test.

## Recommended Next Steps For The Next Agent
1. Check whether `1.01.0 Overture v024` completes downloading.
2. Verify the resulting `v024` WAVs appear under:
   - `/Users/gary/Amira - A Modern Opera/Suno/1_01_0_-_Overture/`
3. Verify those `v024` WAVs are added to:
   - `/Users/gary/Amira - A Modern Opera/Metadata/mix_session.json`
   under:
   - `Songs/1.01.0 - Overture.ows`
4. Re-run the 3-song **cover** bulk test after confirming the single-song completion:
   - `1.01.0 - Overture`
   - `1.02.0 - Prologue`
   - `1.05.0 - Silver`
5. If the bulk test still stalls after upload succeeds, focus next on the **download/polling stage**, not the upload stage.

## Files Touched In This Session
- `/Volumes/Programming/SunoSkill/suno_cli/src/suno_cli/core/tools/basic/tools.py`
- `/Volumes/Programming/Amira Writer/history/HANDOFF-2026-04-21-SUNO-COVER-BULK-DEBUG.md`

## Key Learnings
1. The Prologue bulk-cover failure was caused by brittle multi-file-input selection, not the older missing-CLI or auth bug.
2. The patched uploader now gets the new Overture run all the way through song-ID capture and into the download stage.
3. The remaining post-patch validation is primarily about download completion and bulk re-test confirmation.
