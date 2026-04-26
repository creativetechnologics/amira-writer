# Amira Writer API

Canonical reference for programs and agents that need to drive Amira Writer without a human at the keyboard. The app exposes local loopback HTTP JSON APIs for Score and Animate workflows.

| Interface | When to use | Surface |
|-----------|-------------|---------|
| [HTTP JSON API on `localhost:19847`](#1-http-json-api-localhost19847) | Inspecting / editing / playing back / WAV-exporting in an **already-running app instance** | ~60 endpoints covering songs, notes, tracks, tempo, playback, export, mixer, versions, audio units |
| [Animate agent API on `localhost:19849`](#3-animate-agent-api-localhost19849) | Driving image generation, shot-frame dry-runs, and Image Intelligence from an **already-running app instance** | Places generation, Image Intelligence status/backfill/worker controls, shot-frame dry-run, Vertex image smoke test |

For WAV export specifically, use `POST /api/export/wav` against the running app. The env-var headless full-mix path (`AMIRA_HEADLESS_FULLMIX_EXPORT`) was documented once and retired — it did not work reliably end-to-end from an agent context. Drive the open app instead.

**Do not** use `Scripts/export-headless-wav.sh` or the `Score` package binary for real exports — that binary produces sine tones only, not AudioUnit audio. See [Forbidden paths](#forbidden-paths).

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

## 2. WAV export via the HTTP API

Use `POST /api/export/wav` against the running app. **Always `POST /api/song/select` first**, then re-read `/api/status` afterward to confirm `selectedSongPath` matches what you intended. Skipping the select step exports whatever song happens to be active — usually the first one, which is the #1 cause of repeated first-song exports.

Validate end-to-end (response status, file exists, duration plausible, selected-song matches the request) before asking a human to listen.

---

## 3. Animate agent API (`localhost:19849`)

Animate also starts a loopback-only JSON API when the app opens the Animate workspace. This is the preferred agent control surface for image/shot automation because it runs inside the same app instance Gary is using, with the same project, credentials, UserDefaults, and Vertex auth context.

- Bind: `127.0.0.1:19849`, loopback only.
- Transport: HTTP/1.1 JSON, one request per connection.
- Auth: none beyond the loopback boundary.
- Server source: `Packages/Animate/Sources/AnimateUI/Services/AnimateAPIServer.swift`.

### Status / places

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Current project, selected Nano Banana model, backend, Vertex project/region, Gemini availability |
| `GET` | `/places` | Places/backgrounds with generated-image counts |
| `POST` | `/places/generate` | Queue place image generation in the running app |

Example:

```bash
curl -sS http://127.0.0.1:19849/health | jq

curl -sS -X POST http://127.0.0.1:19849/places/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "place": "Madar Valley",
    "workflow": "photorealistic",
    "model": "nano-banana-2",
    "count": 1,
    "aspectRatio": "16:9",
    "imageSize": "2K",
    "referenceMode": "default"
  }' | jq
```

### Image Intelligence / image AI recognition

These endpoints let an agent check the image-analysis batch state, discover/register project images, queue Gemini visual metadata + image/semantic embeddings, and start/stop the worker.

| Method | Path | Body / query | Purpose |
|--------|------|--------------|---------|
| `GET` | `/image-intelligence/status` | — | Backend config, worker counts, recent jobs, recent logs |
| `POST` | `/image-intelligence/configure` | `{ "backend": "aiStudio" \| "vertex", "vertexProjectID": "...", "vertexRegion": "global" }` | Switch analysis backend/settings and refresh coordinator config. Optional `aiStudioAPIKey` can set the analysis key. |
| `POST` | `/image-intelligence/backfill` | See below | Discover/register images and optionally queue analysis jobs |
| `POST` | `/image-intelligence/worker/start` | — | Start analysis worker |
| `POST` | `/image-intelligence/worker/stop` | — | Stop analysis worker |
| `POST` | `/image-intelligence/queue/reset` | — | Cancel pending/running jobs so they can be requeued |
| `GET` | `/image-intelligence/jobs?limit=100` | — | Recent queue/job records |
| `GET` | `/image-intelligence/logs?limit=100` | — | Recent coordinator logs |
| `GET` | `/image-intelligence/asset?path=/absolute/image.png` | `path` query | Asset registration, jobs, runs, and latest visual metadata for one image |

Backfill body:

```json
{
  "dryRun": true,
  "maxBatchSize": 100,
  "forceReanalysis": false,
  "enqueueExistingWithoutRuns": true,
  "markMissingAssets": true,
  "linkKinds": ["storyboard_frame", "scene_shot_image"],
  "startWorker": false
}
```

Defaults are conservative:

- `dryRun` defaults to `true`; send `"dryRun": false` to actually register/queue.
- `enqueueExistingWithoutRuns` defaults to `true`, so a real backfill queues already-registered images that do not yet have analysis runs.
- `forceReanalysis` defaults to `false`; only set it when you intentionally want to reprocess images with existing runs.

Examples:

```bash
# Check batch/worker state.
curl -sS http://127.0.0.1:19849/image-intelligence/status | jq

# Dry-run discovery for all project images.
curl -sS -X POST http://127.0.0.1:19849/image-intelligence/backfill \
  -H 'Content-Type: application/json' \
  -d '{"dryRun":true}' | jq

# Queue analysis/embeddings for all images without existing runs, then start worker.
curl -sS -X POST http://127.0.0.1:19849/image-intelligence/backfill \
  -H 'Content-Type: application/json' \
  -d '{"dryRun":false,"enqueueExistingWithoutRuns":true,"startWorker":true}' | jq

# Watch progress.
curl -sS http://127.0.0.1:19849/image-intelligence/jobs?limit=50 | jq
```

Headless one-image smoke test (does **not** drain the batch queue):

```bash
.build/debug/Animate --image-intelligence-smoke \
  --project "/path/to/Amira - A Modern Opera" \
  --image "/path/to/existing-project-image.png" \
  --max-spend 1.00
```

The smoke test writes an auditable JSON record to:

```text
<project>/Animate/ImageIntelligenceSmokeTests/image_intelligence_smoke_latest.json
```

For agent-only runs on a machine without `gcloud`, a short-lived OAuth token can be supplied via `AMIRA_VERTEX_ACCESS_TOKEN_FILE`. The app still prefers `gcloud auth application-default print-access-token` from common install paths, including `~/google-cloud-sdk/bin/gcloud`.

### Shot-frame planning and Vertex smoke testing

| Method | Path | Body | Purpose |
|--------|------|------|---------|
| `POST` | `/shot-frames/dry-run` | `{ "scene": "first" \| "all" \| 1 \| "<scene name/id>", "model": "nano-banana-2", "imageSize": "4K" }` | Build the beginning/middle/end plan report without generating images |
| `POST` | `/vertex/image-smoke` | `{ "model": "nano-banana-2", "imageSize": "4K", "aspectRatio": "4:3", "maxSpendUSD": 1.0 }` | Run a single capped Vertex image smoke test inside the running app |

Examples:

```bash
# No-spend shot-frame dry run.
curl -sS -X POST http://127.0.0.1:19849/shot-frames/dry-run \
  -H 'Content-Type: application/json' \
  -d '{"scene":"first","model":"nano-banana-2","imageSize":"4K"}' | jq

# Paid Vertex smoke test, capped to $1.
curl -sS -X POST http://127.0.0.1:19849/vertex/image-smoke \
  -H 'Content-Type: application/json' \
  -d '{"model":"nano-banana-2","imageSize":"4K","aspectRatio":"4:3","maxSpendUSD":1.0}' | jq
```

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
- Realtime render path (click-free shipping path): `ScoreStore.renderChunkToWavViaPlaybackEngine`
- Export buffer fix: `Packages/Score/Sources/ScoreUI/Services/MIDIPlaybackEngine.swift` → `enterExportMode` / `leaveExportMode`
