# Session Handoff — 2026-03-27

## What Happened

### Directory Rename
- Renamed all references from "Novotro Opera" to "Amira Writer" across functional code and active documentation
- Historical docs in `history/` and `Suno/archive/` left as-is

### Mix Page — Selection Fix (commit 60b5175)
- **Root cause:** `@ObservationIgnored` on `selectionOverrides` in MixStore prevented views from ever seeing selection changes
- **Secondary fix:** Replaced NSView-based `MixLaneClickSurface` with SwiftUI `SpatialTapGesture` to eliminate AppKit/SwiftUI double-firing on clicks

### Mix Page — Fade Handles (commit 48f79af)
- Removed "2T · 4C" subtitle from sidebar to match Write/Score
- Replaced triangle fade overlays with S-curve Bezier rendering
- Added drag-to-fade handles at top corners with diagonal resize cursors
- Fixed fade disappearing on release: `autoCrossfadeAroundClip` was resetting user fades above 0.08s

### Score Page — Piano Roll Fixes (commit 48f79af)
- **Labels cascading diagonally:** `CTLineDraw` advances text position which isn't saved by `saveGState` — added `context.textPosition = .zero`
- **No scroll on keyboard:** Added `scrollWheel` override forwarding to `nextResponder`
- **No SF2 preview sound:** `updatePreviewMappingForTrackFilter` now falls back to track 0 instead of nil
- **No AU preview sound:** Added `sendMIDINoteOn/Off` helpers using `scheduleMIDIEventBlock` for AU nodes
- **Buffer underruns during drag:** `configureAudioGraphIfNeeded` now returns immediately when engine running; pitch check moved before expensive sampler calls

### Cross-App Code Audit (commit be2c092)
Six bugs fixed from parallel code review agents:
1. **Mix: Fallback timer leak** — transport timer stored and invalidated on teardown
2. **Mix: Snap-to-grid trim corruption** — snap absolute position, derive delta
3. **Mix: Automation clears clip selection** — preserve current clip ID
4. **Mix: selectedScene getter mutation** — extracted repair into separate method
5. **Score: Metal buffer overrun** — reserve guard changed from -5 to -6
6. **Score: recordingHadWriteError race** — added lock protection for IOThread write

### Outstanding Issues Found (not yet fixed)
- Score: Loop-mode playback clock wrong for A/B regions with non-zero start tick
- Score: `sendHostedMIDIEvent` double sampler lookup — unreachable fallback path
- Score: `withEnginePaused` depth counter issue on engine start failure
- Mix: `Task.isCancelled` always false in DispatchQueue context (browser scan)
- Mix: Fade handle cursor double-push on narrow clips (partially mitigated with guard)

### Write/Shell Audit (commit 6c6e4b5)
Two bugs fixed from Write/Shell review:
7. **App: Redundant Cmd+S save monitor** — removed NSEvent key monitor that was consuming events before SwiftUI CommandGroup could process them, making File > Save menu shortcut permanently dead
8. **Write: Database change overwrites dirty edits** — added dirtySongPaths guard before and after async database load to prevent remote changes from silently discarding unsaved user work

### Outstanding Issues (not yet fixed)
- Score: Loop-mode playback clock wrong for A/B regions with non-zero start tick
- Score: `sendHostedMIDIEvent` double sampler lookup — unreachable fallback path
- Score: `withEnginePaused` depth counter issue on engine start failure
- Mix: `Task.isCancelled` always false in DispatchQueue context (browser scan)
- Mix: Fade handle cursor double-push on narrow clips (partially mitigated with guard)
- Shell: Concurrent project opens can interleave at await points (needs cancellable Task)
- Shell: `reply(toOpenOrPrint: .success)` called before project actually loads

## Current State
- All builds clean, deployed to `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
- Branch `main`, 9 commits ahead of remote
- Mix page: selection, fades, trim, transport all working
- Score page: keyboard labels fixed, preview audio working (SF2 + AU), no underruns
- Write page: dirty-edit protection added for database sync

## Next Steps
- Push to remote when ready
- Fix A/B loop playback clock (Score)
- Add cancellable Task for concurrent project opens (Shell)
- Continue Score page improvements
