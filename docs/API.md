# Amira Writer API

Canonical reference for programs and agents that need to drive Amira Writer without a human at the keyboard. There are **two** programmatic interfaces. Pick the one that fits the job:

| Interface | When to use | Surface |
|-----------|-------------|---------|
| [HTTP JSON API on `localhost:19847`](#1-http-json-api-localhost19847) | Inspecting / editing / playing back a project in an **already-running app instance** | ~60 endpoints covering songs, notes, tracks, tempo, playback, export, mixer, versions, audio units |
| [Headless full-mix WAV export](#2-headless-full-mix-wav-export-env-var-interface) | Rendering a song to WAV from a **headless script** (no UI interaction) | `open -W -n --env AMIRA_HEADLESS_FULLMIX_EXPORT=...` on the app bundle |

Both interfaces drive the full Opera app with BBC SO / SF2 instruments. **Do not** use `Scripts/export-headless-wav.sh` or the `Score` package binary for real exports — that binary produces sine tones only, not AudioUnit audio. See [Forbidden paths](#forbidden-paths).

---

## 1. HTTP JSON API (`localhost:19847`)

### Activation

The HTTP server is started by `ScoreStore.startAPIServer()`. This is called on Score-workspace load — **the app must be navigated to the Score page before the API is reachable**. Launching the app and polling port 19847 from the Write or Animate pages will get you nothing. Navigate to Score first, then begin polling.

- Bind: `127.0.0.1:19847`, loopback only. Not reachable from other machines.
- Transport: HTTP/1.1, JSON bodies, `Content-Type: application/json`.
- CORS: `Access-Control-Allow-Origin: http://127.0.0.1`. `OPTIONS` preflight is handled.
- Auth: none (loopback-only gate).
- Connection lifecycle: one request per connection (`Connection: close` on every response).
- Request size limit: 4 MB. 413 returned if exceeded.
- All handlers run on `@MainActor` — requests serialize through the UI queue. Do not expect high concurrency.

### Response shape

Success:
```json
{ "message": "..." }           // APISuccessResponse, or
{ ...domain-specific fields }  // APIStatusResponse, APINotesResponse, etc.
```

Error:
```json
{ "error": "human-readable message" }
```

Status codes used: `200`, `400` (validation), `404` (unknown endpoint / missing song / missing version / missing file), `405`, `413`, `500` (store unavailable / internal), `501` (not yet supported).

### Endpoint catalog

All paths are prefixed with `/api`. Source of truth: `Packages/Score/Sources/ScoreUI/Services/APIRouter.swift`.

#### Status / introspection

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/status` | App name, version, API port, project name + path, selected song, `isPlaying`, song count |
| `GET` | `/api/songs` | All songs in project (id, relativePath, title, note/track count, version count, has lyrics) |

#### Song content (read)

All of these operate on the currently selected song. Use `POST /api/song/select` first if needed.

| Method | Path | Query / body | Purpose |
|--------|------|--------------|---------|
| `GET` | `/api/song/notes` | `?trackIndex=N&channel=N` (optional filters) | Piano-roll notes |
| `GET` | `/api/song/tracks` | — | Track index, name, channels, note count |
| `GET` | `/api/song/instruments` | — | Instrument mappings + channel-key map |
| `GET` | `/api/song/tempo` | — | BPM, ticksPerQuarter, length, tempo events, time signatures, key signatures |
| `GET` | `/api/song/lyrics` | — | Lyric cues, alignments, libretto text |
| `GET` | `/api/song/markers` | — | Rehearsal markers |
| `GET` | `/api/song/annotations` | — | Score annotations (dynamics, tempo text, expression, rehearsal) |
| `GET` | `/api/song/audio-clips` | — | Audio clips attached to the piano roll |
| `GET` | `/api/song/suno-splits` | — | Suno split ticks + computed chunk boundaries |
| `GET` | `/api/song/versions` | — | Version history of the current song |

#### Song content (write)

| Method | Path | Body | Notes |
|--------|------|------|-------|
| `POST` | `/api/song/select` | `{ "index": N }` or `{ "relativePath": "..." }` | Switches the active song |
| `POST` | `/api/song/notes/add` | `{ "notes": [ APINewNote... ] }` | Returns `{ "noteIDs": [...] }`. Pitch 0-127, velocity 0-127, channel 0-15, duration ≥1, startTick ≥0, trackIndex ≥0. |
| `POST` | `/api/song/notes/delete` | `{ "noteIDs": [uuid, ...] }` | |
| `POST` | `/api/song/notes/update` | `{ "updates": [ APINoteUpdate... ] }` | Partial updates. Validates first, then mutates; unmatched IDs are skipped. |
| `POST` | `/api/song/notes/replace-all` | `{ "notes": [ APINewNote... ] }` | Replaces every note on the song. Array must be non-empty — use `/notes/delete` to clear. |
| `POST` | `/api/song/notes/quantize` | `{ "gridTicks": N, "noteIDs": [...]? }` | Defaults to 16th-note grid if `gridTicks` omitted; all notes if `noteIDs` omitted. |
| `POST` | `/api/song/tracks/rename` | `{ "trackIndex": N, "name": "..." }` | Name clipped to 256 chars. |
| `POST` | `/api/song/instruments/set` | `APISetInstrumentRequest` | See source for full shape; validates SF2 extension + path traversal. |
| `POST` | `/api/song/tempo/set` | `APISetTempoRequest` | BPM 10-500, ticksPerQuarter 1-960, time-signature denominator must be a power of 2, key-sig sharpsFlats -7..7. |
| `POST` | `/api/song/suno-splits/set` | `{ "splitTicks": [N, ...] }` | Ticks ≥ 0. Sorted on save. |
| `POST` | `/api/song/markers/add` | `{ "tick": N, "name": "...", "colorHex": "..." }` | |
| `POST` | `/api/song/markers/delete` | `{ "id": "<uuid>" }` | |
| `POST` | `/api/song/annotations/add` | `{ "tick": N, "text": "...", "kind": "dynamic\|tempo\|expression\|rehearsal", "trackIndex": N? }` | |
| `POST` | `/api/song/annotations/delete` | `{ "annotationID": "<uuid>" }` | |
| `POST` | `/api/song/undo` | — | 400 if nothing to undo. |
| `POST` | `/api/song/redo` | — | 400 if nothing to redo. |
| `POST` | `/api/song/delete` | `{ "songID": "<uuid>" }` | Removes song from project. |

#### Version history

| Method | Path | Body |
|--------|------|------|
| `POST` | `/api/song/versions/snapshot` | `{ "label": "..." }?` |
| `POST` | `/api/song/versions/rollback` | `{ "versionID": "<uuid>" }` |
| `POST` | `/api/song/versions/delete` | `{ "versionID": "<uuid>" }` |
| `POST` | `/api/song/versions/rename` | `{ "versionID": "<uuid>", "newLabel": "..." }` |

#### Playback

| Method | Path | Body / Response |
|--------|------|----------------|
| `POST` | `/api/playback/play` | `{ "startTick": N }?` |
| `POST` | `/api/playback/stop` | — |
| `POST` | `/api/playback/seek` | `{ "tick": N }` |
| `GET`  | `/api/playback/continuous-play` | `{ "enabled": bool }` |
| `POST` | `/api/playback/continuous-play` | `{ "enabled": bool }` |
| `GET`  | `/api/playback/loop` | `{ "enabled": bool, "regionStartTick": N?, "regionEndTick": N? }` |
| `POST` | `/api/playback/loop` | `{ "enabled": bool, "regionStartTick": N?, "regionEndTick": N?, "clearRegion": bool? }` |
| `GET`  | `/api/playback/practice-tempo` | `{ "scale": 1.0, "percent": 100 }` |
| `POST` | `/api/playback/practice-tempo` | `{ "scale": 0.25..2.0 }` or `{ "percent": 25..200 }` |
| `POST` | `/api/playback/jump-to-marker` | `{ "direction": "next" \| "previous" }` or `{ "tick": N }` |
| `GET`  | `/api/playback/meter` | Current peak/RMS L/R + `isPlaying` + `hasSignal` |
| `GET`  | `/api/playback/volume` | `{ "volume": 0.0..1.0 }` |
| `POST` | `/api/playback/volume` | `{ "volume": 0.0..1.0 }` |

#### Export — short renders

**Use these for programmatic clip renders, NOT for full-song WAVs.** Full-song full-mix WAVs should use the [headless env-var interface](#2-headless-full-mix-wav-export-env-var-interface) so the app bundle can be launched fresh and terminate when done.

| Method | Path | Body |
|--------|------|------|
| `POST` | `/api/export/wav` | `{ "outputPath": "...", "startTick": N?, "endTick": N?, "overrideSF2Path": "...?" }` — path must not contain `..`; SF2 must have `.sf2/.sf3/.dls` extension. |
| `POST` | `/api/export/rehearsal` | `{ "outputPath": "...", "accompanimentAttenuationDB": -12.0? }` |
| `POST` | `/api/export/stems` | `{ "outputDir": "..." }` |
| `POST` | `/api/export/suno-chunks` | `{}` — exports to `~/Desktop` (custom `outputDir` returns 501 for now) |
| `POST` | `/api/import/musicxml` | `{ "filePath": "/path/to/file.xml" }` |

#### Mixer

| Method | Path | Body |
|--------|------|------|
| `POST` | `/api/song/tracks/mute` | `{ "trackIndex": N }` (toggle) |
| `POST` | `/api/song/tracks/solo` | `{ "trackIndex": N }` (toggle) |
| `POST` | `/api/song/tracks/clear-solo` | — |
| `POST` | `/api/song/tracks/pan` | `{ "mappingKey": "...", "pan": -1.0..1.0 }` |

#### Project lifecycle

| Method | Path | Body |
|--------|------|------|
| `POST` | `/api/project/save` | — |
| `POST` | `/api/project/open` | `{ "path": "..." }` |

#### Instruments / Audio Units

| Method | Path | Body / Purpose |
|--------|------|----------------|
| `GET`  | `/api/soundfonts` | Lists `.sf2` / `.sf3` / `.dls` files in the sample browser |
| `GET`  | `/api/audio-units` | `{ "isScanning": bool, "audioUnits": [ APIAudioUnitInfo... ] }` |
| `GET`  | `/api/audio-units/state` | Live-engine AU state dump (string entries) |
| `POST` | `/api/audio-units/set` | `{ "mappingKeys": [...], "componentType": OSType, "componentSubType": OSType, "manufacturer": OSType, "name": "..." }` |
| `GET`  | `/api/instruments/mode` | `{ "mode": "soundFont" \| "audioUnit", "mappingCount": N }` |
| `POST` | `/api/instruments/mode` | `{ "mode": "soundFont" \| "audioUnit" }` (also accepts `sf2/lightweight` and `au/heavyweight`) |

#### Debug

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/api/debug/playback-state` | Raw `ScoreStore.PlaybackDiagnostics` dump |
| `POST` | `/api/debug/try-play` | Snapshot diagnostics, call `playPianoRoll`, snapshot again — returns before/after |

### Minimal client example

```bash
# 1. Launch the app; navigate to the Score page (human or automation).
# 2. Wait for port 19847.
until curl -sS --max-time 1 http://127.0.0.1:19847/api/status > /dev/null; do sleep 1; done

# 3. Call it.
curl -sS http://127.0.0.1:19847/api/status | jq
curl -sS http://127.0.0.1:19847/api/songs  | jq '.songs[].title'

curl -sS -X POST http://127.0.0.1:19847/api/song/select \
  -H 'Content-Type: application/json' \
  -d '{"relativePath":"Songs/1.01.0 - Overture.ows"}'

curl -sS -X POST http://127.0.0.1:19847/api/playback/play \
  -H 'Content-Type: application/json' \
  -d '{"startTick":0}'
```

### Request/response types

Swift-side types live in `Packages/Score/Sources/ScoreUI/Services/APITypes.swift` (`APINewNote`, `APISetInstrumentRequest`, `APISetTempoRequest`, etc.). Read that file for the exact field names and optionality. All types use JSON camelCase field names matching the Swift property names.

---

## 2. Headless full-mix WAV export (env-var interface)

For producing a clean, click-free full-mix WAV of a song with BBC Symphony Orchestra AudioUnits **without** requiring the app to already be running on the Score page. This is a launch-the-bundle-with-env-vars workflow; the app boots headless, loads the project, renders the song, writes the WAV, and terminates itself.

**Canonical doc:** [`docs/HOW-TO-EXPORT-WAV.md`](HOW-TO-EXPORT-WAV.md) — read it in full before invoking. It explains song-hint traps (`"Finale"` ≠ Johnny's Goodbye Finale), the flaky XPC cold start (retry once), the verification checklist, and the hard constraints (no BBC SO patches, no SF2 fallback, no post-hoc WAV repair).

### Environment variables

Consumed by `Sources/Opera/OperaApp.swift` → `applicationDidFinishLaunching` and dispatched to `ScoreBootstrap.runHeadlessFullMixExport(outputURL:songHint:)`.

| Env var | Purpose | Default |
|---------|---------|---------|
| `AMIRA_HEADLESS_FULLMIX_EXPORT` | Absolute path for output WAV. **Presence of this var triggers headless export mode.** | unset → GUI mode |
| `AMIRA_HEADLESS_FULLMIX_SONG` | Song name hint. Substring match against `relativePath` or `displayName`. Use a unique substring — `"Finale"` matches `1.28.0 - Something More (Act I Finale)`, not Johnny's Goodbye. | unset → first song in project |
| `AMIRA_HEADLESS_LOG_FILE` | Absolute path for dup2'd stderr / `NSLog` output — this is where you read markers from. | `<output>.headless-log.txt` |
| `AMIRA_HEADLESS_FORCE_OFFLINE` | Skip qualification, force offline render path. | **Do not set.** Offline has audible click artifacts; the realtime+4096-buffer path is the shipping config. |
| `AMIRA_EXPORT_THROTTLE_SPEED` | Per-block sleep cap for offline render (e.g. `5.0`). | **Do not set.** Only affects the abandoned offline path. |

### Invocation template

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

- `open -W` blocks until the app quits (the headless hook terminates it after export).
- `open -n` forces a fresh instance (the user may already have the GUI app open).
- `--env` injects env vars into the launched process. **`launchctl setenv` does not propagate to apps launched via LaunchServices — do not use it.**

### Verification

After `open` returns:

1. File exists and is non-zero: `ls -la "$OUT"`
2. Duration matches expected: `afinfo "$OUT" | head -15` (expect `2 ch, 48000 Hz, Float32, interleaved`)
3. Log shows success: `grep -E "resolved song|done status" "$LOG"` — expect `[HeadlessFullMix] done status=success bytes=<N> path=<OUT>`
4. Click-free buffer confirmed: log contains `[ExportBuffer] entered export mode, bufferSize=4096 frames (was 512)`
5. **`resolved song` matches the song you asked for.** Do not skip this. A successful export of the wrong song is a real failure mode (see below).

Validate end-to-end before asking a human to listen.

### Exporting multiple songs — do not repeat the first song

Previous agents have silently exported the first song in the project over and over while believing they were advancing through a list. Defend against it explicitly:

- `AMIRA_HEADLESS_FULLMIX_SONG` is **required** to target anything other than song index 0. An unset, empty, or non-matching hint falls back to the first song — every time. This is the #1 cause of repeated first-song exports.
- Each `open -W -n` invocation exports **exactly one song**. There is no batch mode. For N songs, launch N times with different `AMIRA_HEADLESS_FULLMIX_SONG` **and** different `AMIRA_HEADLESS_FULLMIX_EXPORT` paths.
- Use a unique, specific hint per song (full `relativePath` or a distinctive substring like `"Johnny's Goodbye"`). Avoid generic substrings like `"Finale"` that collide with earlier songs.
- **`grep "resolved song" "$LOG"` after every run** and compare against the requested hint. File size / duration / `done status=success` can all be green while the wrong song is in the WAV.
- Encode the intended song in the output filename (`overture-…wav`, `johnnys-goodbye-…wav`) so a misrouted export is visible in `ls`.
- If two consecutive runs meant to be different songs produce the same `resolved song:` line, **stop and diagnose.** Do not launch a third run.

For HTTP-API-driven exports (`POST /api/export/wav`), the equivalent rule is: **always `POST /api/song/select` before `POST /api/export/wav`, and re-read `/api/status` afterward to confirm `selectedSongPath` matches what you intended.** Skipping the select step exports whatever song happens to be active — usually the first one.

---

## Forbidden paths

The following exist in the tree but **must not be used for real exports**:

- `Scripts/export-headless-wav.sh` — drives the `Score` package binary, which is a Swift-package-only target with no AppKit/AudioUnit host. It produces sine tones, not BBC SO / SF2 audio.
- `swift run -c release Score --headless-export-wav ...` — same problem; same binary.
- Any "realtime fallback / offline fallback" framing. The shipping config **is** the realtime-capture path with the 4096-frame export buffer (commit `ca679fcf`). Don't describe it as a fallback and don't build an "if offline fails, use realtime" layer — just use realtime.
- Post-render WAV repair (crossfading, deglitching, trimming). Any fix must be in-render.
- BBC SO plugin patches (`fullState`, XML, `rr_play`, `rr_count`, etc.). BBC SO stays stock.
- SF2 fallback for full-mix exports. The WAV must be rendered with BBC SO when the project uses it.

## Source-of-truth files

- HTTP server: `Packages/Score/Sources/ScoreUI/Services/APIServer.swift`
- HTTP router: `Packages/Score/Sources/ScoreUI/Services/APIRouter.swift`
- HTTP request/response types: `Packages/Score/Sources/ScoreUI/Services/APITypes.swift`
- Server lifecycle: `ScoreStore.startAPIServer()` / `stopAPIServer()` in `Packages/Score/Sources/ScoreUI/ScoreStore.swift`
- Headless export entry point: `Packages/Score/Sources/ScoreUI/ScoreBootstrap.swift` → `runHeadlessFullMixExport(outputURL:songHint:)`
- Env var dispatch: `Sources/Opera/OperaApp.swift` → `applicationDidFinishLaunching`
- Realtime render path (click-free shipping path): `ScoreStore.renderChunkToWavViaPlaybackEngine`
- Export buffer fix: `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` → `enterExportMode` / `leaveExportMode`
