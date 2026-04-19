# Handoff — 2026-04-18 — Hosted AU Export Qualification

## Current goal

We have been trying to make hosted Audio Unit / BBC WAV export faster than realtime **without sacrificing audio quality or introducing defects**.

The current architecture keeps the safe realtime export path as the default for any hosted-AU mapping set that does not pass qualification. That safety behavior is still in place and is working.

## User constraints

- Do **not** save or overwrite the intentional song-data edits made by another agent:
  - percussion notes were removed from all songs
  - velocities were normalized to 40%
- All validation should stay **non-destructive**
- Real export tests should write to **temporary output paths**
- Every meaningful code change should be **committed to git**
- GUI app validation should use the deployed app bundle in:
  - `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

## Where the code stands now

### Safe behavior already implemented

- Hosted-AU export supports:
  - `auto`
  - `realtime`
  - `offline`
- `auto` mode:
  1. renders a short offline qualification excerpt
  2. renders the same excerpt through the trusted realtime playback-engine path
  3. compares the two
  4. promotes offline render **only if** the result passes strict thresholds
  5. otherwise falls back to realtime export automatically

### Qualification work already in place

- persisted qualification cache in Application Support
- multi-profile offline qualification:
  - `standard`
  - `conservative`
- MFCC similarity comparison
- RMS-envelope similarity comparison
- active audible duration comparison
- silence-aware hosted-AU tail stopping
- leading-alignment support
- preserved failed qualification artifacts:
  - realtime excerpt WAV
  - offline excerpt WAVs
  - metadata JSON

### Latest hardening added

Latest commit:

- `7369f1d0` — `Harden hosted-AU qualification analysis`

This added:

- retries when opening/reading freshly rendered qualification excerpts
- a wait window for audible-bound analysis
- copied-clone fallback analysis for just-written excerpt files
- cache/version bump to `v13`

## Important current result

The app is still **correctly falling back to realtime** for the tested hosted-AU mapping set.

That is the right behavior for now.

However, the remaining blocker is:

- qualification metadata still reports:
  - `onsetDelta=nans`
  - `tailDelta=nans`

even though the preserved excerpt WAVs are valid and externally analyzable.

## What we know for sure

### Valid preserved artifacts exist

Latest preserved qualification artifacts:

- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Opera/HostedAudioUnitQualificationArtifacts/1776560123-hosted-au-qualification-v13___Volumes_Storage VIII_Users_gary_Amira - A Modern O/metadata.json`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Opera/HostedAudioUnitQualificationArtifacts/1776560152-hosted-au-qualification-v13___Volumes_Storage VIII_Users_gary_Amira - A Modern O/metadata.json`

These artifacts include valid WAV files such as:

- `realtime.wav`
- `standard.wav`
- `conservative.wav`

### External inspection proves the files are not empty/broken

Using external analysis on the preserved v13 files, the bounds are detectable. Example:

- `realtime.wav`
  - first audible frame ≈ `33`
  - last audible frame ≈ `2548800`
- `standard.wav`
  - first audible frame ≈ `289`
  - last audible frame ≈ `2564375`

So the remaining bug is **not** “the excerpt renders are missing.”

It is much more likely that:

- one of the in-process qualification bound reads is still returning `nil`, or
- the specific source used to compute onset/tail deltas is not the one we think it is

## Latest observed qualification details

From the current v13 preserved metadata:

- standard:
  - `similarity=0.4482`
  - `envelope=0.0000`
  - `activeDelta=0.324s`
  - `fileDelta=0.324s`
  - `onsetDelta=nans`
  - `tailDelta=nans`
  - verdict: `rejected`
- conservative:
  - `similarity=0.0000`
  - `envelope=0.0000`
  - `activeDelta=0.324s`
  - `fileDelta=0.324s`
  - `onsetDelta=nans`
  - `tailDelta=nans`
  - verdict: `rejected`

## Most likely next step

The next highest-value move is **not** more threshold tuning.

The next step should be to instrument exactly **which bounds source is nil** during qualification:

- realtime original
- offline original
- offline clone fallback

Right now the preserved artifacts prove the files exist and contain audible content, but the qualification detail still collapses to `NaN`.

Until that exact nil source is logged, further tuning is mostly guesswork.

## Files most relevant to continue from here

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/Sources/ScoreUI/ScoreStore.swift`
  - main hosted-AU qualification logic
  - audible-bound analysis
  - cache/versioning
  - artifact preservation
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-04-18-fast-au-export-qualification.md`
  - running checkpoint/spec for this work
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/Sources/ScoreUI/Services/MFCCSimilarity.swift`
  - similarity analysis helper used by qualification

## Last successful validation

Deployed app:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Verified timestamps:

- app: `2026-04-18 17:52:22 PDT`
- binary: `2026-04-18 17:52:23 PDT`

Latest successful non-destructive export:

- `/private/tmp/amira-fast-export-v13.iuY6O1/overture-v13.wav`

Verified with `afinfo`:

- stereo
- `48000 Hz`
- `Float32`
- duration about `179.7s`
- audio bytes `69004800`

Latest live app sweep completed through:

- Write
- Score
- Mix
- Imagine
- Characters
- Places
- Props
- Animate
- All Images
- Write

## Bottom line

The system is currently **safe but not yet fast** for this hosted-AU mapping set.

That is acceptable for now because:

- realtime export works
- the app does not crash
- the fallback logic is behaving correctly

The remaining work is now very specific:

> identify why qualification bound analysis still produces `NaN` onset/tail deltas even though the preserved excerpt WAVs are valid and externally analyzable.
