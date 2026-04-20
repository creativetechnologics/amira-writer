# How to Export a Full-Mix WAV (Headless, BBC SO)

Canonical procedure for producing a clean, click-free full-mix WAV of an Amira opera song using BBC Symphony Orchestra Audio Units. **All agents must use this method.** Do not improvise alternatives — the constraints below exist because every alternative has been tried and rejected.

## Shipping config (what works)

- **Path:** realtime capture via `renderChunkToWavViaPlaybackEngine`
- **Buffer:** 4096-frame export buffer (installed automatically by `MIDIPlaybackEngine.enterExportMode()` — commit `ca679fcf`)
- **Plugin:** BBC Symphony Orchestra, stock (no patches)
- **Qualification cache routing:** let the cache decide. Do not set `AMIRA_HEADLESS_FORCE_OFFLINE` — the offline path produces audible click artifacts that no in-render fix has eliminated.

## Command

```bash
TS=$(date +%Y%m%d-%H%M%S)
OUT="/Users/gary/Desktop/${SONG_SLUG}-${TS}.wav"
LOG="/Users/gary/Desktop/${SONG_SLUG}-${TS}.log"

open -W -n \
  --env "AMIRA_HEADLESS_FULLMIX_EXPORT=$OUT" \
  --env "AMIRA_HEADLESS_FULLMIX_SONG=$SONG_HINT" \
  --env "AMIRA_HEADLESS_LOG_FILE=$LOG" \
  "/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
```

- `open -W` blocks until the app quits (the headless hook terminates the app after export).
- `open -n` forces a fresh instance — required since the user may have the app open.
- `--env` injects the env var into the launched process. `launchctl setenv` is NOT inherited by apps launched via LaunchServices; do not use it.

## Song hint matching

The hint matches the first song where `relativePath == hint || relativePath.contains(hint) || displayName == hint`. **Partial matches can hit the wrong song.**

| Hint | Resolves to |
|------|-------------|
| `"Finale"` | `1.28.0 - Something More (Act I Finale)` (first match) — **NOT** Johnny's Goodbye Finale |
| `"Johnny's Goodbye"` | `2.23.0 - Johnny's Goodbye - Finale` (unique) |
| `"Overture"` | `1.01.0 - Overture` |

**Always verify the resolved song** in the log after launch:

```
[Phase1cHook] runHeadlessFullMixExport resolved song: 2.23.0 - Johnny's Goodbye - Finale
```

If the resolved song is wrong, re-run with a more specific hint.

### Exporting multiple songs — DO NOT REPEAT THE FIRST SONG

Past agents have silently exported the same song (the first one in the project) over and over while believing they were advancing through a list. To avoid this:

1. **`AMIRA_HEADLESS_FULLMIX_SONG` is required** when exporting anything other than song index 0. If the env var is unset OR matches nothing, the app falls back to **the first song in the project** — the same first song, every time. An empty, stale, or unset hint is the #1 cause of repeated first-song exports.
2. **Give each launch a unique, specific hint.** Don't reuse one variable and forget to update it. Don't pass a generic substring like `"Finale"` that collides with an earlier song; use the song's full `relativePath` or a substring unique to that song (`"Johnny's Goodbye"`, `"Act II Opener"`).
3. **Parse the `resolved song` line from the log after every single run** before treating the WAV as done. Do not trust file size, duration, or the fact that the export "succeeded" — a successful export of the wrong song is the exact failure mode here.
4. **Compare the resolved song against the requested hint.** If they don't match, delete the WAV, widen the hint, and retry. Don't keep appending more WAVs and hope the next one is right.
5. **Give every output WAV a filename that encodes the intended song** (e.g. `overture-…wav`, `johnnys-goodbye-…wav`) so a misrouted export is visible in `ls`, not buried inside identical-looking files.
6. **Each `open -W -n` invocation exports exactly one song.** There is no batch mode. To export N songs, launch the bundle N times, each with a different `AMIRA_HEADLESS_FULLMIX_SONG` and a different `AMIRA_HEADLESS_FULLMIX_EXPORT` path, and verify each run's `resolved song` before moving on.
7. **If you ever see the same `resolved song:` line twice in a row across two runs that were meant to be different songs, stop.** Something is wrong with your hint plumbing — diagnose before launching a third run.

## Expected wall-clock time

Roughly **realtime** (the render streams through BBC SO at ~1x realtime for heavy instrument counts). Add ~30-60s for project load + AU instantiation + qualification (first run) or cache lookup (subsequent runs). Budget a watchdog timeout of `audio_duration + 120s`.

## Verification checklist

After the command returns, check:

1. **WAV exists and has non-zero size:**
   ```bash
   ls -la "$OUT"
   ```
2. **Expected duration:**
   ```bash
   afinfo "$OUT" | head -15
   ```
   Compare `estimated duration: X sec` against the song's expected duration. File format should be `2 ch, 48000 Hz, Float32, interleaved`.
3. **Log confirms success:**
   ```bash
   grep -E "resolved song|done status" "$LOG"
   ```
   Expect `[HeadlessFullMix] done status=success bytes=<N> path=<OUT>`.
4. **Path confirmation** — the log should contain `[ExportBuffer] entered export mode, bufferSize=4096 frames (was 512)` which confirms the click-free buffer fix is active.

## Flaky cold start (known issue)

On the first headless launch after the app bundle has been idle, BBC SO's XPC process launch occasionally aborts at `AudioUnitInitialize → CAVerboseAbort` when loading many instruments simultaneously (17+ instances — Finale and similar). Symptoms:

- App exits in ~4s
- No WAV file produced
- Crash report at `~/Library/Logs/DiagnosticReports/Opera-*.ips` with `EXC_BREAKPOINT` on `com.novotro.score.playback` queue

**Remedy:** retry once. This is an XPC flakiness, not a code bug. Second run almost always succeeds.

## Known issue: first-beat clipping in realtime path

The realtime capture path currently loses the attack of notes scheduled at tick 0 (the tap starts capturing slightly after playback begins). This is a known, accepted limitation. Do **not** attempt to "fix" it by switching to the offline path — the offline path's click artifacts are much worse than missing attacks.

## Build + deploy

If the app bundle is missing or you've made code changes:

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
bash Scripts/build-app.sh
```

Installs to `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`, ad-hoc signed. Do NOT deploy anywhere else — the `!Applications` sync handles propagation.

## Env vars reference

| Env var | Purpose | Default |
|---------|---------|---------|
| `AMIRA_HEADLESS_FULLMIX_EXPORT` | Absolute path for output WAV (triggers headless export mode) | unset → GUI mode |
| `AMIRA_HEADLESS_FULLMIX_SONG` | Song name hint (substring match on relativePath/displayName) | unset → first song in project |
| `AMIRA_HEADLESS_LOG_FILE` | Absolute path for dup2'd stderr/NSLog output | `<output>.headless-log.txt` |
| `AMIRA_HEADLESS_FORCE_OFFLINE` | Skip qualification, force offline render | **do not set** (offline has clicks) |
| `AMIRA_EXPORT_THROTTLE_SPEED` | Per-block sleep cap for offline render, e.g. `5.0` | **do not set** (offline-only; dead code for shipping path) |

## Hard constraints — do not violate

These are standing rules from Gary. Breaking any of them will be rejected.

- **No BBC SO patches.** Do not modify `fullState`, XML, `rr_play`, `rr_count`, or any plugin-internal parameter to work around issues. BBC SO stays stock.
- **No SF2 fallback.** The WAV must be rendered with BBC SO. Do not route to AVAudioUnitSampler / SF2.
- **No "realtime fallback" as a separate path.** The shipping config IS the realtime-capture path with 4096-frame buffer. Don't describe it as a fallback; don't build an "if offline fails, use realtime" layer — just use realtime.
- **No post-hoc WAV repair.** Do not crossfade, deglitch, or otherwise modify the file after render. Any fix must be in-render.
- **Gary is not the tester.** Validate end-to-end (verify resolved song, check WAV duration, confirm `done status=success`) before asking Gary to listen.

## References

- Implementation: `Packages/Score/Sources/ScoreUI/ScoreStore.swift`
  - Realtime path: `renderChunkToWavViaPlaybackEngine` (~line 5172)
  - Qualification cache routing: ~line 5125
  - Offline path (not used for shipping): `renderChunkToWavBackground` (~line 5357)
- Buffer fix: `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` → `enterExportMode`/`leaveExportMode` (commit `ca679fcf`)
- Headless entry point: `Packages/Score/Sources/ScoreUI/ScoreBootstrap.swift` → `runHeadlessFullMixExport(outputURL:songHint:)`
- Env var dispatch: `Sources/Opera/OperaApp.swift` → `applicationDidFinishLaunching`
