# Character Data Loss Restoration — Final Handoff
**Date:** 2026-05-26 23:22 PDT  
**Project:** `/Users/gary/Amira - A Modern Opera`  
**App source:** `/Volumes/Programming/Amira Writer`  
**Verified app:** `/Users/gary/Programming/!Applications/Amira Writer.app`  
**Status:** Fixed and verified in UI with Computer Use

## Summary
The Characters page is working again with the recent generated character art and background cast restored. The final fix required both data repair in the Amira project and code hardening in Amira Writer so the refactored app does not choose stale duplicate rigs or save over richer character data.

## Root Cause
- Rich generated assets had been split into duplicate `Characters/*-2` folders while their restored rigs referenced canonical paths.
- Stale local duplicate character records with old slugs (`johnny`, `luke`, `mark`, `matt`, `new-character`) could share canonical IDs/storage slugs and overwrite the canonical `rig.json` on save.
- Legacy rig JSON stored some dates as Apple-reference numeric dates; the refactored strict decoders expected strings, so master/head/costume/model payloads could fail decode and get dropped by fallback paths.

## Data Restored
- Canonical project character manifest: `/Users/gary/Amira - A Modern Opera/Characters/characters.json`
- 67 characters and 1,362 OPW image records.
- Principal rich reference workflow counts:
  - Johnny Ward: 153 inspiration, 31 animated, 9 master sheets, 21 head variants, 8 costume sheets, 21 full-body variants.
  - Luke Hart: 133 inspiration, 35 animated, 4 master sheets, 24 head variants, 7 costume sheets, 43 full-body variants.
  - Mark Price: 79 inspiration, 13 animated, 6 master sheets, 6 head variants, 2 costume sheets, 12 full-body variants.
  - Matt Quill: 80 inspiration, 13 animated, 1 master sheet, 6 head variants, 6 costume sheets, 36 full-body variants.
  - Yasmin Nazari: 83 inspiration, 6 animated, 1 master sheet, 50 look-development slots.
  - Amira Nazari: 78 inspiration, 24 animated, 1 master sheet.
- Background examples now show their generated references too; Townsperson 001 has 1 shot reference, 1 master sheet, and 1 full-body/costume pose.

## Archives Created
- `/Users/gary/Amira - A Modern Opera/_Archive/20260526-225557-before-canonical-character-asset-merge/Characters`
- `/Users/gary/Amira - A Modern Opera/_Archive/20260526-225628-removed-duplicate-character-folders-after-merge/`

## App Source Changes
- `/Volumes/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
  - Chooses richest persisted rig candidates by reference-asset score.
  - Deduplicates stale sync rows by ID/storage slug.
  - Adds save-time guard against destructive character reference asset loss.
  - Shares lossy legacy rig recovery between persisted-character paths.
  - Invalidates asset URL cache on external rig reload.
- `/Volumes/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/CharacterLookDevelopmentModels.swift`
  - Adds `LegacyFlexibleDateDecoding` and uses it for look-development variants.
- `/Volumes/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`
  - Uses flexible legacy dates for `CharacterInspirationBatchJob` and `Character3DModel`.

## Build / Deploy
- `swift build -c debug --product Opera` via `/Users/gary/bin/server-run`: passed with warnings only.
- `Scripts/build-app.sh` via `/Users/gary/bin/server-run`: passed with warnings only; Developer ID signing failed and the script fell back to stable ad-hoc signing.
- Deployed binary SHA-256: `136f49549762670622dc475a57920c9929ba46f72b0d6860f51145115bbd8df3`
- Matching binaries installed at:
  - `/Volumes/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera`
  - `/Users/gary/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera`

## Computer Use Verification
Verified the exact local installed app at `/Users/gary/Programming/!Applications/Amira Writer.app`:
- Sidebar includes the main six plus background characters.
- Johnny Ward: visible thumbnails/profile/reference images; UI shows `Master Sheets 9`, `Head Poses 6`, `Full Body 7`, overview `Inspiration Images 153`, `Head Poses 6/6`, `Costume Poses 7`.
- Luke Hart: visible thumbnails/profile/reference images; UI shows `Master Sheets 4`, `Head Poses 6`, `Full Body 12`, overview `Inspiration Images 133`, `Head Poses 6/6`, `Costume Poses 12`.
- Townsperson 001: visible profile, shot reference, and master images; UI shows `Shot Reference Images 1 refs`, `Master Sheets 1`, `Full Body 1`, `Inspiration Images 1`, `Costume Poses 1`.

## Post-UI Validation
The validation script run after UI navigation passed:
- 67 manifest characters.
- 1,362 manifest image records.
- All checked profile images resolve on disk.
- No active `Characters/*-2` duplicate directories.
- Johnny and Luke rich counts remained intact after the app reported `Saved`.
- Recent logs had no new rig/date decode errors.

## Follow-Up
- Commit/preserve the app source changes.
- Avoid running stale duplicate Amira Writer bundles when testing this issue.
- If future file-level character repairs are needed, quit/relaunch only with Gary's permission and re-test through Computer Use before handoff.
