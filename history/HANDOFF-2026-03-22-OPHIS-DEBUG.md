# Ophis Debug Handoff

Date: March 22, 2026
Workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`
Repo status at handoff: uncommitted local edits in:
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Sources/Opera/OperaShellView.swift`

## Immediate user-reported blockers

These are still broken in the latest deployed build:

1. `Score` still does not play from the piano roll.
   - User symptom: pressing play does nothing.
   - Toolhead does not move.
   - This persists after the latest attempted `ScoreStore` playback patch.

2. Switching to `Animate` can still wedge the shell.
   - User symptom: the loading overlay appears.
   - Then the “agent updated / syncing” badge starts flashing.
   - Nothing finishes loading.
   - The shell becomes effectively stuck behind the loading screen and the user cannot switch back out cleanly.

3. The most recent shipped build was rebuilt and deployed to Gary’s laptop, but the user immediately confirmed both issues still reproduce there.

## What was attempted already

### 1. Score playback patch that did NOT solve it

File touched:
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`

Changes currently in the working tree:
- Added `pendingPlaybackStartTask`.
- Added deferred playback recovery in `playPianoRoll(...)` when the selected song is still lightweight-loaded and has no in-memory playback yet.
- Allowed playback to proceed when there are playable audio clips even if MIDI notes are empty.
- Cancel pending deferred playback start when stopping playback or changing selected song.

Current relevant lines after the patch:
- `ScoreStore.swift:1501`
- `ScoreStore.swift:2974`
- `ScoreStore.swift:3046`

Why this matters:
- The current hypothesis was that the selected song existed only as a lightweight placeholder, so `playPianoRoll(...)` saw no notes and silently failed before hydration finished.
- The patch queued hydration and retried play automatically.
- User says it still does not work, so the bug is likely upstream of this fallback or deeper in the load/start path.

### 2. Animate shell timeout patch that did NOT solve it

File touched:
- `Sources/Opera/OperaShellView.swift`

Changes currently in the working tree:
- Added recent-project migration and filtering.
- Added auto-open of the most recent valid project on launch.
- Added `loadForModeSwitch(...)` with an Animate-specific timeout path intended to let Animate continue loading in the background instead of blocking the whole shell.

Current relevant lines after the patch:
- `OperaShellView.swift:50`
- `OperaShellView.swift:203`
- `OperaShellView.swift:316`
- `OperaShellView.swift:404`
- `OperaShellView.swift:436`

Why this matters:
- The intent was to stop `Animate` mode-switch from holding the shell in `.loading` indefinitely.
- User says the app still wedges behind the loading screen when switching to Animate, so either:
  - the timeout path is not actually being reached,
  - `loadState` is still not getting cleared,
  - or something else is reasserting the loading/sync state after the timeout.

## Likely fault lines to inspect first

### A. Score

Most likely files:
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Views/PianoRollViewController.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Services/ProjectDatabaseBridge.swift`
- `Packages/NovotroScore/Sources/NovotroScore/Services/MIDIPlaybackEngine.swift`

Most likely root-cause buckets:

1. The selected song is never actually hydrating into a playable asset.
   - Inspect:
     - `loadSelectedMidiIfPossible()`
     - `hydrateSongDetailsIfNeeded(id:includePlayback:)`
     - `ProjectDatabaseBridge.loadSceneAsset(...)`
     - `OWPProjectIO.loadSongAsync(stub:)`
   - Verify at runtime:
     - `selectedMidiID`
     - `selectedMidiAsset?.relativePath`
     - `songAsset.document.activeVersion()?.playback != nil`
     - `pianoRollNotes.count`
     - `pianoRollAudioClips.count`
     - whether `hydrateSongDetailsIfNeeded(...)` returns `true`

2. The play button path is not reaching a viable play start.
   - Inspect:
     - `PianoRollViewController.togglePlayPause()`
     - whether `autoRenderVocalTracksIfNeeded()` is returning cleanly
     - whether `store.playPianoRoll(...)` is actually called

3. The playback engine is not transitioning to active state even after notes exist.
   - Inspect:
     - `MIDIPlaybackEngine.play(...)`
     - `playOnAudioQueue(...)`
     - `setPlaying(true)`
     - `onPlaybackStateChange`
   - Verify whether `playbackEngine.isPlaying` ever flips to true.

Strong suggestion:
- Add temporary logging around `togglePlayPause()`, `playPianoRoll(...)`, `hydrateSongDetailsIfNeeded(...)`, and `MIDIPlaybackEngine.play(...)`.
- The key question is whether the failure is:
  - empty data,
  - hydration never completing,
  - or engine start not occurring.

### B. Animate

Most likely files:
- `Sources/Opera/OperaShellView.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/NovotroAnimateWorkspace.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/AnimateStore.swift`
- `Packages/NovotroAnimate/Sources/NovotroAnimate/Services/ProjectDatabaseBridge.swift`

Most likely root-cause buckets:

1. `handleModeSelectionChange(...)` is still waiting on a path that never resolves.
   - Inspect:
     - `OperaShellView.handleModeSelectionChange(_:)`
     - `OperaShellView.loadForModeSwitch(mode:projectURL:)`
     - whether `.timedOut` is ever returned
     - whether `loadState` is always set back to `.idle`

2. Animate open is re-entering itself or reloading continuously.
   - Inspect:
     - `AnimateStore.openOWP(url:preferService:)`
     - `AnimateStore.startBackgroundIndexRefresh(projectURL:database:)`
     - `AnimateStore.startDatabaseWatch()`
     - `AnimateStore.startExternalFileWatch()`
     - `AnimateStore.beginAgentSync()`
     - `AnimateStore.markAgentUpdated(paths:)`

3. Background index refresh may be reopening the project and causing a sync loop.
   - In `AnimateStore.startBackgroundIndexRefresh(...)`, note that a changed token can trigger:
     - `await self.openOWP(url: projectURL, preferService: false)`
     - then `markAgentUpdated()`
   - Combined with the watches and external-change polling, this may be creating a loop or permanent busy state.

Strong suggestion:
- Temporarily disable or short-circuit these one at a time to isolate the wedge:
  - `startBackgroundIndexRefresh(...)`
  - `startDatabaseWatch()`
  - `startExternalFileWatch()`
- Determine which one causes the flashing sync badge / stuck loading behavior.

## Important historical context

There were several recent architectural changes before this debug pass:

1. Fast-open / lightweight load behavior was added so projects can open before full cold data is hydrated.
2. Disk became the source of truth for song membership/order while the project DB remained a cache.
3. Background index refreshes and external-change syncing were added across Write / Score / Animate.
4. The shell was changed to use its own recent-project store and workspace-switch loading overlay.

The current failures are very likely fallout from interaction between:
- lightweight load / deferred hydration,
- background index refresh,
- external change syncing,
- and shell-level loading state.

## What is already known NOT to be enough

These two patches alone did not fix the user-facing regressions:

1. `ScoreStore` deferred playback retry.
2. `OperaShellView` Animate timeout / recent-project migration patch.

## Build / deploy details

Latest build/deploy completed successfully before user re-tested:

Build:
```bash
/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/build-app.sh
```

Deploy:
```bash
scp -r "/Volumes/Storage VIII/Users/gary/Applications/Novotro Opera.app" gary@Garys-Laptop.local:~/Applications/
```

The build succeeded and the app bundle was copied to Gary’s laptop, but the user confirmed the regressions still reproduce in that shipped build.

## Recommended debugging order for Ophis

1. Reproduce `Score` play failure on the exact user project.
2. Instrument the Score transport path to determine whether the problem is:
   - no playback data,
   - hydration not finishing,
   - or playback engine not starting.
3. Reproduce the `Animate` wedge.
4. Instrument the shell load-state transitions and Animate store sync/watch cycle.
5. Identify which watcher / background refresh path is causing the persistent loading + flashing sync behavior.
6. Only after the blockers are resolved, re-check recent-project behavior. That shell patch may be fine, but it is lower priority than restoring Score playback and Animate usability.

## Working tree note

At handoff time the workspace has local uncommitted edits in:
- `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift`
- `Sources/Opera/OperaShellView.swift`

Those edits represent attempted fixes that should be reviewed carefully rather than assumed correct.
