# Handoff: Instrument Mode Switch Bug (SF2 ↔ AU)

## Current Status

**✅ FIXED (2026-03-22)**

**Bug**: Switching from lightweight (SF2/SoundFont) → heavyweight (AU/Audio Unit) → back to lightweight causes playback to completely break. The playhead doesn't move and no sound plays. SF2→AU works. AU playback works. AU→SF2 deadlocks.

**Root cause**: `loadSoundBankInstrument()` (Apple framework call on `AVAudioUnitSampler`) deadlocks when called on the `audioQueue` after out-of-process Audio Unit plugins have been previously instantiated via `AVAudioUnit.instantiate(with:options:.loadOutOfProcess)`.

**Solution**: Dispatch SF2 loading to `DispatchQueue.global(qos: .userInitiated)` instead of running directly on `audioQueue`. The `loadSoundBankInstrument()` call likely dispatches synchronously to the audio queue internally, causing deadlock when we're already on that queue. By dispatching the load to a global queue, we avoid the deadlock while still waiting for all loads to complete via `DispatchGroup.wait()`.

**Implementation**: 
- Modified `reloadAllInstruments()` in `MIDIPlaybackEngine.swift` to dispatch SF2 loading to a global queue
- Created new `loadInstrumentOffQueue()` method that doesn't require being on the audioQueue
- Cache updates are dispatched back to audioQueue for thread safety

---

## Architecture

### Key Files

| File | Purpose |
|------|---------|
| `Packages/NovotroScore/Sources/NovotroScore/Services/MIDIPlaybackEngine.swift` | Audio engine — samplers, AU instruments, playback scheduling. **This is where the bug is.** |
| `Packages/NovotroScore/Sources/NovotroScore/ScoreStore.swift` | Score state — `setMasterInstrumentMode()` at ~line 963 triggers the mode switch |
| `Packages/NovotroScore/Sources/NovotroScore/Services/APIRouter.swift` | HTTP API endpoints for remote control |
| `Packages/NovotroScore/Sources/NovotroScore/Services/APIServer.swift` | Lightweight HTTP server on port 19847 |
| `Sources/NovotroOpera/OperaShellView.swift` | Shell view with file-based remote control (`/tmp/novotro-command.txt`) |

### Key Functions in MIDIPlaybackEngine.swift

- **`reloadAllInstruments(mappings:)`** (~line 638): Called after mode switch. Currently attempts to: stop engine, deallocate AU render resources, detach AU nodes, create new samplers, load SF2s, restart engine. The SF2 loading deadlocks.
- **`sampler(for:mapping:)`** (~line 1654): Creates/returns an AVAudioUnitSampler for a mapping key. Creates the sampler, attaches it, connects it to mainMixerNode, loads the SF2.
- **`loadAudioUnitIfNeeded(mappingKey:mapping:description:)`** (~line 1702): Instantiates an AU plugin out-of-process using a semaphore to block.
- **`withEnginePaused(_:)`** (~line 2406): Pauses engine before topology changes, restarts after. Recently changed to ALWAYS pause when engine is running (was previously conditional on `isPlaying`).
- **`loadInstrument(_:into:mappingKey:)`** (~line 1907): Loads an SF2 file into an AVAudioUnitSampler via `loadSoundBankInstrument()`. This is where the deadlock occurs.
- **`playOnAudioQueue(...)`** (~line 2449): Sets up hosted MIDI playback. Calls `sampler(for:mapping:)` lazily for each note group.
- **`configureAudioGraphIfNeeded()`** (~line 2400): Starts the audio engine.
- **`setPlaying(_:)`** (~line 3711): Sets the `isPlaying` flag.

### Key Properties

- `audioQueue`: Serial `DispatchQueue` — ALL engine work runs here
- `engine`: `AVAudioEngine` (private let, cannot be replaced)
- `samplerByMappingKey`: `[String: AVAudioUnitSampler]` — SF2 samplers
- `auInstrumentByMappingKey`: `[String: AVAudioUnit]` — AU instrument nodes
- `panMixerByMappingKey`: `[String: AVAudioMixerNode]` — per-AU pan mixers
- `patchSignatureByMappingKey`: Cache to avoid redundant loads
- `isPlaying`: Whether transport is active
- `isReconfiguring`: Guard flag to prevent health check interference

### Mode Switch Flow

1. User (or API) calls `ScoreStore.setMasterInstrumentMode(.soundFont)` or `.audioUnit`
2. ScoreStore stops playback if active, calls `InstrumentMapping.applyMasterToggle()` to update all mapping `effectiveSourceType` values
3. Calls `playbackEngine.reloadAllInstruments(mappings: instrumentMappings)`
4. `reloadAllInstruments` dispatches to `audioQueue` and rebuilds the audio graph

---

## Remote Testing Setup

### Machines

- **Build Server**: `Garys-Server.local` — source code at `/Volumes/Storage VIII/Programming/Novotro Opera/`
- **Laptop**: `Garys-Laptop.local` — runs the app, has Spitfire BBC Symphony AU installed

### Build & Deploy Commands

```bash
# Build (on server)
cd "/Volumes/Storage VIII/Programming/Novotro Opera" && bash Scripts/build-app.sh

# Deploy to laptop
scp -r "/Volumes/Storage VIII/Users/gary/Applications/Novotro Opera.app" "gary@Garys-Laptop.local:~/Applications/"

# Re-sign on laptop (SSH can't access keychain)
ssh gary@Garys-Laptop.local "codesign --force --sign - --deep ~/Applications/Novotro\ Opera.app"

# Kill and relaunch
ssh gary@Garys-Laptop.local "pkill -f 'Novotro Opera' 2>/dev/null; sleep 2; open ~/Applications/Novotro\ Opera.app"
```

### Remote Mode Switching

The app polls `/tmp/novotro-command.txt` every 500ms for mode commands:

```bash
# Switch to Score mode
ssh gary@Garys-Laptop.local "echo 'score' > /tmp/novotro-command.txt"

# Switch to Write mode
ssh gary@Garys-Laptop.local "echo 'write' > /tmp/novotro-command.txt"

# Switch to Animate mode
ssh gary@Garys-Laptop.local "echo 'animate' > /tmp/novotro-command.txt"
```

### Score API (port 19847)

```bash
# Check if Score API is up
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/status"

# Get current instrument mode
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/instruments/mode"

# Switch to AU (heavyweight)
ssh gary@Garys-Laptop.local "curl -s -X POST -H 'Content-Type: application/json' -d '{\"mode\":\"audioUnit\"}' http://localhost:19847/api/instruments/mode"

# Switch to SF2 (lightweight)
ssh gary@Garys-Laptop.local "curl -s -X POST -H 'Content-Type: application/json' -d '{\"mode\":\"soundFont\"}' http://localhost:19847/api/instruments/mode"

# Start playback
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/play"

# Stop playback
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/stop"

# Check playback state
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/debug/playback-state"

# Try play (diagnostic — plays from tick 0 and returns before/after state)
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/debug/try-play"
```

### Engine Debug Log

The MIDIPlaybackEngine writes detailed logs to `/tmp/novotro-engine.log`:

```bash
# Read full log
ssh gary@Garys-Laptop.local "cat /tmp/novotro-engine.log"

# Tail log
ssh gary@Garys-Laptop.local "tail -30 /tmp/novotro-engine.log"

# Clear log (do this before a test run)
ssh gary@Garys-Laptop.local "echo '' > /tmp/novotro-engine.log"

# Check if reloadAllInstruments completed
ssh gary@Garys-Laptop.local "grep -c 'reloadAllInstruments complete' /tmp/novotro-engine.log"

# Check last lines (if it stopped growing, audioQueue is deadlocked)
ssh gary@Garys-Laptop.local "wc -l /tmp/novotro-engine.log"
```

### Full Cycle Test Script

This is the exact test that reproduces the bug:

```bash
# Wait for app startup, switch to Score
sleep 6
ssh gary@Garys-Laptop.local "echo 'score' > /tmp/novotro-command.txt"
sleep 6

# Verify Score mode loaded
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/instruments/mode"
# Expected: {"mappingCount":25,"mode":"soundFont"}

# Clear log
ssh gary@Garys-Laptop.local "echo '' > /tmp/novotro-engine.log"

# Step 1: Play SF2 (should work)
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/play"
sleep 3
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/debug/playback-state | python3 -c \"import sys,json; d=json.load(sys.stdin); print('SF2:', d['isPlaying'])\""
# Expected: SF2: True

# Step 2: Stop, switch to AU
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/stop"
sleep 1
ssh gary@Garys-Laptop.local "curl -s -X POST -H 'Content-Type: application/json' -d '{\"mode\":\"audioUnit\"}' http://localhost:19847/api/instruments/mode"
sleep 12  # AU plugins take ~10s to load out-of-process

# Step 3: Play AU (should work)
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/play"
sleep 3
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/debug/playback-state | python3 -c \"import sys,json; d=json.load(sys.stdin); print('AU:', d['isPlaying'])\""
# Expected: AU: True

# Step 4: Stop, switch back to SF2
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/stop"
sleep 1
ssh gary@Garys-Laptop.local "curl -s -X POST -H 'Content-Type: application/json' -d '{\"mode\":\"soundFont\"}' http://localhost:19847/api/instruments/mode"
sleep 8

# Step 5: Play SF2 after cycle (THIS IS THE BUG)
ssh gary@Garys-Laptop.local "curl -s -X POST http://localhost:19847/api/playback/play"
sleep 5
ssh gary@Garys-Laptop.local "curl -s http://localhost:19847/api/debug/playback-state | python3 -c \"import sys,json; d=json.load(sys.stdin); print('SF2-cycle:', d['isPlaying'])\""
# BUG: SF2-cycle: False (should be True)

# Check engine log for deadlock
ssh gary@Garys-Laptop.local "tail -5 /tmp/novotro-engine.log"
# Will show loadSoundBankInstrument() was the last call — it never returned
```

---

## What Has Been Tried (All Failed)

1. **engine.stop() + detach AUs + create samplers + load SF2 + engine.start()** — `loadSoundBankInstrument()` deadlocks
2. **engine.reset()** — same deadlock
3. **Disconnect AUs (don't detach) + load SF2** — same deadlock
4. **Mute AU pan mixers (don't disconnect) + load SF2** — same deadlock
5. **Lazy SF2 loading via `sampler(for:mapping:)` in playOnAudioQueue** — same deadlock (the lazy path also calls `loadSoundBankInstrument()` on the audioQueue)
6. **deallocateRenderResources() before detach** — same deadlock
7. **Thread.sleep(0.1-0.2) between AU cleanup and SF2 loading** — same deadlock
8. **Changed `withEnginePaused` to always pause when engine is running** — same deadlock
9. **engine.stop() first, then deallocateRenderResources, then detach, then load SF2** — same deadlock

## What Fixed It (2026-03-22)

**Dispatch SF2 loading off the audioQueue**: The key insight was that `loadSoundBankInstrument()` internally dispatches synchronously to the audioQueue when AU XPC connections exist. Since we're already on the audioQueue, this causes deadlock.

Solution: Dispatch all SF2 loads to `DispatchQueue.global(qos: .userInitiated)` using a `DispatchGroup` to wait for completion. This allows the internal dispatch to complete withoutdeadlock.

Changes made to `MIDIPlaybackEngine.swift`:
1. In `reloadAllInstruments()`, create samplers and attach them while still on audioQueue
2. Dispatch `loadInstrumentOffQueue()` calls to global queue for each SF2 sampler
3. Use `DispatchGroup.wait()` to block until all loads complete
4. Continue with engine start and AU loading on audioQueue

New method `loadInstrumentOffQueue()` mirrors `loadInstrument()` but:
- Skips cache check (already cleared at reload start)
- Dispatches cache update back to audioQueue for thread safety

---

## Suggested Next Steps (Untried)

### 1. Dispatch SF2 loading off the audioQueue
The deadlock might be caused by `loadSoundBankInstrument()` internally dispatching synchronously to the audioQueue. Since we're already on the audioQueue, this would deadlock. Try:

```swift
// In reloadAllInstruments, after creating and attaching samplers:
let sf2Group = DispatchGroup()
for (key, mapping) in mappings where mapping.effectiveSourceType != .audioUnit {
    guard let s = self.samplerByMappingKey[key] else { continue }
    s.volume = 1.0
    sf2Group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        self.loadInstrument(mapping, into: s, mappingKey: key)
        sf2Group.leave()
    }
}
sf2Group.wait()  // Block audioQueue until all SF2s loaded
```

**Risk**: `loadInstrument` accesses `patchSignatureByMappingKey` which is only safe on audioQueue. May need to wrap that part.

### 2. Use a fresh AVAudioEngine
Since `engine` is `private let`, change it to `private var` and create a brand new `AVAudioEngine()` when switching from AU→SF2. This completely sidesteps any lingering XPC state:

```swift
// In reloadAllInstruments, when switching AU→SF2:
self.engine.stop()
// Clear all node tracking
self.samplerByMappingKey.removeAll()
self.auInstrumentByMappingKey.removeAll()
self.panMixerByMappingKey.removeAll()
// Create fresh engine
self.engine = AVAudioEngine()
// Rebuild from scratch...
```

### 3. Process-level AU isolation
The Spitfire AU plugin runs out-of-process via XPC. The XPC host process may leave global state (shared memory, mach ports) that interferes. Check if killing the AU host processes helps:

```bash
ssh gary@Garys-Laptop.local "pkill -f AUHostingService"
```

Then try loading SF2s.

### 4. Test with a simpler AU
The Spitfire BBC Symphony is a very complex AU. Test if the bug reproduces with Apple's built-in DLSMusicDevice AU (type=`aumu`, subType=`dls `, manufacturer=`appl`). If it doesn't reproduce, the bug is Spitfire-specific.

### 5. Investigate with lldb
Attach to the process and check what `loadSoundBankInstrument` is waiting on:

```bash
ssh gary@Garys-Laptop.local "lldb -p \$(pgrep -f 'Novotro Opera')"
# Then in lldb:
# thread list
# thread backtrace all
# Look for the audioQueue thread and see what it's blocked on
```

---

## Other Fixed Issues (Completed)

These bugs were fixed earlier in this session and are working:

1. **Score playback no sound** — Fixed by removing `setenv("NOVOTRO_DISABLE_SCORE_API_SERVER", "1", 1)` from NovotroOperaApp.swift
2. **CPU spike (900%)** — Fixed by disabling external file watcher for Opera mode in Score and Animate stores
3. **Animate mode-switch stalling** — Fixed by `suspendBackgroundWork()` on mode switch + `sqlite3_busy_timeout(5000)`
4. **`withEnginePaused` not pausing** — Fixed by changing condition to `shouldPause = engine.isRunning` (always pause when running)

---

## Build System

- Swift 6.2 / macOS 26 (Tahoe)
- Build command: `bash Scripts/build-app.sh` (in project root)
- Build time: ~70-90 seconds
- Output: `/Volumes/Storage VIII/Users/gary/Applications/Novotro Opera.app`
- The app requires macOS 26.0 (both build server and laptop run it)

---

## Important Notes

- The app uses `@available(macOS 26.0, *)` throughout
- The Spitfire BBC Symphony Orchestra AU is installed on the laptop, NOT the server
- The Score API server runs on port 19847 (localhost only)
- File-based remote control uses `/tmp/novotro-command.txt`
- Engine debug log is at `/tmp/novotro-engine.log`
- `fileLog()` in MIDIPlaybackEngine writes timestamped entries to the engine log
- The audioQueue is a SERIAL dispatch queue — this is likely key to the deadlock
- Always wait 6+ seconds after launching the app before sending commands
- Always wait 10-12 seconds after switching to AU mode for plugins to load
- The project is at `/Volumes/Storage VIII/Programming/Novotro Opera/`
