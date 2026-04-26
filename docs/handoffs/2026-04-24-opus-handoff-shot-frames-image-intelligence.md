# Handoff to Opus — Shot Frames, Storyboards, Image Intelligence, Vertex, and Agent APIs

**Date:** 2026-04-24 PDT
**Repo:** `/Volumes/Storage VIII/Programming/Amira Writer`
**Project tested:** `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera`
**Reason for handoff:** Gary is switching to Opus for a few days to save Codex tokens. When Gary returns to Codex, resume from the **Next Best Steps** section below.

---

## First-read instructions for Opus / next agent

1. **Do not reset or broadly clean the working tree.** The repo is intentionally dirty from a multi-step feature build. Preserve existing edits unless Gary explicitly asks otherwise.
2. **Use the canonical app workspace:** `/Volumes/Storage VIII/Programming/Amira Writer`.
3. **If you change the GUI app or deployable code, finish with:**
   - `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh`
   - verify `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app` timestamp/hash.
4. **Do not manipulate Gary's laptop apps without permission.** SSH checks are okay when appropriate; do not quit/relaunch/open apps on the laptop unless Gary approves.
5. **Vertex spend must be explicit and capped.** Project-local smoke/cost records already exist under the Amira project; continue that pattern.
6. **Current architectural direction:** script/storyboard/source-of-truth information should automatically drive shot beginning/middle/end frame generation, with automatic character/place/reference image attachment and minimum manual intervention.
7. **Current model preference:** Nano Banana 2 is the default image-generation model; Nano Banana Pro is a custom selectable option only.

---

## Executive summary

Over the last build stretch we moved from concept planning toward a working foundation for one-button shot-frame automation:

- Designed the shot script model around **direction / action / camera** plus storyboard-image overrides.
- Added storyboard/iPad drawing infrastructure and recovery sidecars so drawn begin/middle/end frames can participate in planning.
- Built Image Intelligence around project images, SQLite, Gemini/Vertex visual analysis, embeddings, tags, and reference selection.
- Wired Image Intelligence into shot-frame planning so Gemini/Nano Banana frame requests can attach likely reference images automatically.
- Added open-matte/crop-control planning so camera pans/tilts/zooms can be represented as deterministic crops instead of asking the image model to guess camera movement.
- Added agent/API controls for Image Intelligence, shot-frame dry runs, and Vertex smoke testing.
- Tested the Image Intelligence tagging pipeline with existing project images under a Vertex cap, found real bugs, fixed them, and confirmed metadata/tags/embeddings/tag search now work.
- Cleaned the old orphaned Image Intelligence runs after Gary approved it.

The system is **not finished**, but the important plumbing is now in place and validated at least for a single existing image through Vertex.

---

## What Gary asked for conceptually

Gary wants a pipeline where the script is the source of truth and a single button can eventually generate beginning/middle/end frames for the whole show:

1. In the script UI:
   - `directions` = plain-text visual direction / what the shot looks like.
   - `storyboarding` becomes more like `action`.
   - `animate` becomes more like `camera`.
   - A `shot summary` can combine all of the above in plain language.
2. Each shot needs enough metadata to identify:
   - characters present,
   - place/location,
   - time of day,
   - landmarks,
   - spatial/sun orientation,
   - frame composition / screen position when useful.
3. Storyboard drawings from iPad should work synergistically:
   - drawn storyboard begin/middle/end frames can override or clarify text,
   - image analysis should read those storyboard images,
   - text + storyboard analysis should merge into shot-frame planning.
4. Frame generation should maintain continuity:
   - first frame often prompt + references,
   - middle/end frames often Gemini/Nano Banana edit prompts from prior frame when continuity is more important,
   - system should decide generate-vs-edit per frame.
5. Camera movement should often be algorithmic:
   - generate wider/open-matte plates (e.g. 4:3 / 4K),
   - crop to 16:9 for video-generator input,
   - possibly final crop to 21:9,
   - simulate pans/tilts/zooms via deterministic crop keyframes.
6. Automatic reference attachment:
   - character refs from Characters page / animated ref sheets,
   - places and landmarks from Places page,
   - nearest matching reference images via vector/tags/metadata,
   - agent-visible preview of what got attached.

---

## Main implementation areas completed

### 1. iPad storyboard drawing + storyboard recovery

Key goals:
- iPad can draw beginning/middle/end storyboard frames.
- Storyboard PNGs are first-class assets for Image Intelligence.
- Storyboard analysis sidecars can be recovered/registerable.

Important files in this area:
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/index.html`
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/app.js`
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/drawing.js`
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/style.css`
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/manifest.webmanifest`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardAPIServer.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardRouter.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardAssets.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/AnimateStore+Storyboard.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardFrameAnalysisSidecarStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardAnalysisPromptBuilder.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardServerStatusModel.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardServerIndicatorView.swift`

Notable status:
- Storyboard web UI was visually tested earlier via WebKit/iPad-size stub runs.
- Storyboard PNGs are discoverable as `storyboard_frame` Image Intelligence assets.
- Storyboard recovery state is visible in the title-bar/storyboard indicator surfaces.

### 2. Image Intelligence subsystem

Image Intelligence is the local/project image understanding layer.

Core store:
- DB path: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/.novotro/image-intelligence.sqlite`
- Main schema includes:
  - `image_assets`
  - `image_asset_links`
  - `image_analysis_runs`
  - `image_visual_metadata`
  - `image_tags`
  - `image_tag_assignments`
  - `image_embeddings`
  - `image_analysis_jobs`
  - `image_qc_flags`

Important files:
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageIntelligenceStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAssetDiscoveryService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAssetInspector.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackfillService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisCoordinator.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/GeminiImageAnalysisService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/VertexImageAnalysisClient.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackendStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageSearchService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/README.md`

Recent fixes in this area:
- Vertex request shape fixed:
  - `contents` now includes `role: "user"`.
  - invalid `generationConfig.thinkingLevel` removed.
  - Vertex `embedContent` body no longer sends body-level `model`.
- Vertex auth improved:
  - image-analysis client now searches `~/google-cloud-sdk/bin/gcloud` in addition to Homebrew/system paths.
  - `AMIRA_VERTEX_ACCESS_TOKEN_FILE` and `AMIRA_VERTEX_ACCESS_TOKEN` can be used for agent-run smoke tests.
- Tagging fixed:
  - retrieval/asset-role tags now write to `image_tags` and `image_tag_assignments`.
  - `ImageSearchService.searchByTags` now finds smoke-tested assets.
- New direct single-asset analysis path:
  - avoids draining existing batch queue during smoke tests.

### 3. Image Intelligence smoke test and Vertex validation

New CLI:

```bash
.build/debug/Animate --image-intelligence-smoke \
  --project "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera" \
  --image "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Inspiration/portrait_photo_of_matt_mttq39__neutral_background_-text__watermark__anime_123(5).png" \
  --max-spend 1.00
```

Implemented in:
- `Packages/Animate/Sources/Animate/AnimateMain.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

Successful smoke result:
- Image: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Inspiration/portrait_photo_of_matt_mttq39__neutral_background_-text__watermark__anime_123(5).png`
- Status: `succeeded`
- Summary: `A clean, professional headshot of a young man with short hair and a beard wearing a navy blue shirt.`
- Short caption: `Portrait of a man with a beard against a gray background.`
- Tags included:
  - `man`
  - `portrait`
  - `beard`
  - `blue eyes`
  - `short hair`
  - `navy t-shirt`
  - `gray background`
  - `headshot`
  - `studio lighting`
- `tagAssignmentCount=10`
- `embeddingCount=2`
- `tagSearchHit=true`

Cost records:
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/ImageIntelligenceSmokeTests/image_intelligence_smoke_latest.json`
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/ImageIntelligenceSmokeTests/manual_vertex_probe_latest.json`
- Conservative local tracked estimate for the test session: `$0.10`, under Gary's `$1` cap.

### 4. Image Intelligence orphan cleanup

Gary approved cleaning out the orphans after the smoke test.

Before cleanup:
- `image_analysis_runs`:
  - `completed = 1`
  - `running = 4635`
- `image_analysis_jobs`:
  - `failed = 1545`
  - `pending = 20`
  - `running = 0`
- Therefore every running run was orphaned.

Backup made first:
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/.novotro/backups/image-intelligence-before-orphan-cleanup-20260424-125039.sqlite`
- raw sidecar backup copies also saved in the same backup directory.

Cleanup action:
- Marked 4,635 orphaned `image_analysis_runs` rows from `running` to `failed`.
- Added:
  - `error_code='orphaned_running_run_cleanup'`
  - explanatory error message.
- Did **not** delete rows.
- Did **not** touch 20 pending jobs.
- Did **not** delete/archive 1,545 old failed jobs.

After cleanup:
- `completed runs = 1`
- `failed runs = 4635`
- `remainingOrphanRunningRuns = 0`
- `PRAGMA integrity_check = ok`
- no foreign-key check failures.

Cleanup report:
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/ImageIntelligenceMaintenance/orphan-cleanup-latest.json`

### 5. Shot-frame dry-run / open-matte crop planning

Gary requested traditional filmmaking-style open matte generation:
- render wider/taller than final framing,
- use crop movement algorithmically for pans/tilts/zooms,
- feed video generators 16:9 crops,
- preserve headroom for final 21:9 crop.

Implemented/plumbed concepts:
- default open-matte source plate: 4:3 / 4K style planning,
- 16:9 extraction metadata,
- 21:9 delivery headroom metadata,
- normalized crop rects / keyframes,
- deterministic crop plans for camera motion.

Important files:
- `Packages/Animate/Sources/AnimateUI/Models/ShotFrameGenerationPlan.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ShotFrameGenerationPlanResolver.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ShotFrameGenerationDryRunPlanner.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`
- `Packages/Animate/Sources/Animate/AnimateMain.swift`

CLI dry-run command:

```bash
.build/debug/Animate --shot-frame-dry-run \
  --project "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera" \
  --scene first \
  --model nano-banana-2 \
  --image-size 4K
```

Dry-run reports are written under:
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/Imagine/DryRuns/`

### 6. Gemini/Nano Banana generation/edit continuity hardening

Important decisions/fixes:
- Nano Banana 2 is the default model going forward.
- Nano Banana Pro remains selectable/custom only.
- Middle/end frames may often be better as Gemini/Nano Banana **edit** prompts from prior frames, not fresh generations.
- Edit-mode shot frames now require the continuity source image; missing/unreadable/oversized sources fail visibly rather than silently degrading to prompt-only generation.
- Gemini image sidecars are best-effort after the image bytes are saved; sidecar write failures should not throw away a successfully generated image.
- Vertex image-generation attempt ledgers are visible in settings/UI and record auth/setup failures.

Important files:
- `Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`
- `Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Models/ShotFrameGenerationPlan.swift`

### 7. Agent/API controls

Added loopback app API endpoints for agent workflows on `127.0.0.1:19849`.

Important file:
- `Packages/Animate/Sources/AnimateUI/Services/AnimateAPIServer.swift`

Docs:
- `docs/API.md`

Important endpoints added:
- `GET /image-intelligence/status`
- `POST /image-intelligence/configure`
- `POST /image-intelligence/backfill`
- `POST /image-intelligence/worker/start`
- `POST /image-intelligence/worker/stop`
- `POST /image-intelligence/queue/reset`
- `GET /image-intelligence/jobs?limit=100`
- `GET /image-intelligence/logs?limit=100`
- `GET /image-intelligence/asset?path=/absolute/image.png`
- `POST /shot-frames/dry-run`
- `POST /vertex/image-smoke`

Important behavior:
- Backfill defaults are conservative: `dryRun=true` by default.
- `enqueueExistingWithoutRuns=true` is supported for real backfills.
- Agents should prefer the app API when the app is open and the workspace is loaded, because it inherits the app/user runtime context.
- In the last test, the API was not listening on server or laptop, so the CLI smoke path was used instead.

---

## Validation / deployments completed

### Latest Image Intelligence smoke/fix validation

Commands/results:
- `swift build -c debug --product Animate` — passed.
- `swift test --filter ImageIntelligence` from `Packages/Animate` — passed, 31 tests.
- `git diff --check` for touched files — passed.
- `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh` — passed and deployed.

Latest deployed app:
- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
- Bundle mtime: `2026-04-24 12:15:19 PDT`
- Executable: `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera`
- Executable mtime: `2026-04-24 12:15:34 PDT`
- SHA256: `6ddc6870203e7a7f1a6276d9544157d1e72740fe2f3232930d47eab1ec3e8f57`
- `codesign --verify --deep --strict` passed.

### Earlier API deployment

Before the smoke-test fixes, the app was also deployed after API controls:
- SHA256 at that time: `2475946cb3b5f3f2913dc9d36b97b85c53d29af0cd672147c366eeed7916b89b`
- Superseded by latest deployment above.

---

## Current known project DB state after cleanup

For:
- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/.novotro/image-intelligence.sqlite`

Current important counts:
- `image_assets = 1566`
- `image_analysis_runs`:
  - `completed = 1`
  - `failed = 4635` (cleanup-marked old orphans)
- `image_analysis_jobs`:
  - `failed = 1545`
  - `pending = 20`
- `image_visual_metadata = 1`
- `image_embeddings = 2`
- `image_tags = 10`
- `image_tag_assignments = 10`
- `remaining orphan running runs = 0`

Do not interpret the 4,635 failed runs as new live failures. They are old orphans marked failed for cleanup/audit.

---

## Important gotchas and fixes already learned

### Vertex image analysis request shape

Correct Vertex `generateContent` requirements discovered by live test:
- `contents` must include `role: "user"`.
- `generationConfig.thinkingLevel` is not accepted in this API shape.
- `responseMimeType` and `responseSchema` are OK.

Correct Vertex `embedContent` requirement:
- model is in URL:
  - `.../models/gemini-embedding-2:embedContent`
- do **not** include a body-level `model`, or Vertex returns HTTP 400.

### gcloud path

Gary's Laptop has working gcloud here:
- `/Users/gary/google-cloud-sdk/bin/gcloud`

The server did not have `gcloud` in the common checked paths during the earlier test. Do not conclude Vertex is broken just because server CLI lacks gcloud. The app/laptop can have working auth.

### Tag search requirement

`ImageSearchService.searchByTags` joins:
- `image_tag_assignments`
- `image_tags`

So visual metadata JSON alone is not enough. Any future analysis path must keep persisting real tag rows.

### Avoid draining queues during smoke tests

The direct one-image smoke path exists because the project can have large existing queues/failures. For controlled testing, use `--image-intelligence-smoke`, not worker start/backfill, unless you intentionally want batch processing.

---

## Current working tree warning

The repo has many modified/untracked files from the broader ongoing feature build. This is expected. Do not run broad cleanup commands.

Representative modified/untracked areas include:
- storyboard web resources,
- Image Intelligence services,
- Animate API server,
- shot-frame planning models/services,
- Imagine generation services/views,
- Score/Write/Opera UI state from earlier work,
- docs/plans/handoffs.

Before editing, use targeted diffs only for the files you intend to touch.

---

## Next Best Steps

### Immediate next step A — expose one-image smoke through app API

We now have CLI:
- `--image-intelligence-smoke`

But the loopback API does not yet have an equivalent single-image endpoint. Since Gary explicitly wants agents to operate by opening the app and sending API calls, add something like:

- `POST /image-intelligence/smoke`

Suggested body:

```json
{
  "path": "/absolute/project/image.png",
  "backend": "vertex",
  "vertexProjectID": "vertex-493406",
  "vertexRegion": "global",
  "maxSpendUSD": 1.0
}
```

It should call the same direct single-asset path as the CLI and write the same project-local report.

### Immediate next step B — decide what to do with pending/failed jobs

After orphan cleanup, remaining queue/history:
- `20` pending jobs,
- `1545` old failed jobs.

Do **not** touch these without Gary's explicit instruction. Options to offer:
1. cancel pending jobs only,
2. requeue pending jobs under the fixed Vertex code,
3. archive old failed jobs to a report then delete them,
4. leave all historical job rows untouched.

### Immediate next step C — run a two-image or storyboard-image smoke test

Now that one portrait succeeded, the next useful smoke test is a storyboard/image reference style case:
- test one storyboard PNG with actual drawn content if available,
- or one place/landmark/reference image,
- confirm metadata/tags/embeddings/tag search,
- optionally test `ImageSearchService.selectForShot` after a few diverse images are analyzed.

Keep spend capped and write reports.

### Medium next step D — UI status/badges

Add image-grid/inspector badges for:
- unregistered,
- registered/no run,
- pending,
- running,
- analyzed,
- failed,
- cleanup-marked old failure.

This would make the All Images page more operationally trustworthy.

### Medium next step E — shot-frame reference resolver QA

Once a handful of characters/places/storyboards have metadata/tags/embeddings, test whether shot-frame plans actually choose the right automatic references.

Use:
- `--shot-frame-dry-run`
- inspect reference counts and attached paths,
- compare expected character/place/storyboard references.

### Medium next step F — script UI rename/model work

The conceptual rename has been planned but likely not fully applied across UI/data model:
- directions -> plain text / shot visual description,
- storyboarding -> action,
- animate -> camera,
- shot summary as combined plain-text input.

This needs careful migration/UI work so existing script markup is not broken.

---

## Command cookbook

### Check Image Intelligence DB status

```bash
DB="/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/.novotro/image-intelligence.sqlite"
sqlite3 -header -column "$DB" "
SELECT status, COUNT(*) AS count FROM image_analysis_runs GROUP BY status;
SELECT status, COUNT(*) AS count FROM image_analysis_jobs GROUP BY status;
SELECT COUNT(*) AS remaining_orphan_running_runs
FROM image_analysis_runs r
WHERE r.status='running'
  AND NOT EXISTS (
    SELECT 1 FROM image_analysis_jobs j
    WHERE j.image_asset_id=r.image_asset_id AND j.status='running'
  );
PRAGMA integrity_check;
"
```

### Run one-image Image Intelligence smoke test from CLI

If running on server without gcloud, use Gary's laptop token carefully without persisting it:

```bash
TOKEN_FILE=$(mktemp /tmp/amira-vertex-token.XXXXXX)
chmod 600 "$TOKEN_FILE"
ssh -o BatchMode=yes -o ConnectTimeout=5 gary@Garys-Laptop.local \
  '/Users/gary/google-cloud-sdk/bin/gcloud auth application-default print-access-token' > "$TOKEN_FILE"

AMIRA_VERTEX_ACCESS_TOKEN_FILE="$TOKEN_FILE" \
  .build/debug/Animate --image-intelligence-smoke \
  --project "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera" \
  --image "/absolute/path/to/existing/project/image.png" \
  --max-spend 1.00

rm -f "$TOKEN_FILE"
```

### Build/deploy app

```bash
/Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh
APP="/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
stat -f 'bundle_mtime=%Sm' -t '%Y-%m-%d %H:%M:%S %Z' "$APP"
find "$APP/Contents/MacOS" -maxdepth 1 -type f -print -exec shasum -a 256 {} \;
codesign --verify --deep --strict "$APP"
```

### Image Intelligence tests

From package directory:

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate"
swift test --filter ImageIntelligence
```

---

## Files most likely relevant to next work

### API / CLI
- `Packages/Animate/Sources/AnimateUI/Services/AnimateAPIServer.swift`
- `Packages/Animate/Sources/Animate/AnimateMain.swift`
- `docs/API.md`

### Image Intelligence
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageIntelligenceStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisCoordinator.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/VertexImageAnalysisClient.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackendStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackfillService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAssetDiscoveryService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageSearchService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/README.md`

### Store / workspace
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift`

### Shot-frame planning
- `Packages/Animate/Sources/AnimateUI/Models/ShotFrameGenerationPlan.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ShotFrameGenerationPlanResolver.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ShotFrameGenerationDryRunPlanner.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`

### Storyboard
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardAPIServer.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardRouter.swift`
- `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardFrameAnalysisSidecarStore.swift`
- `Packages/Animate/Sources/AnimateUI/Resources/storyboard-web/`

---

## Return-to-Codex note

Gary is handing this to Opus temporarily. When Gary returns to Codex in a few days, **start here**:

1. Read this handoff.
2. Check `agent_sync` latest handoff for `/Volumes/Storage VIII/Programming/Amira Writer`.
3. Check `mcp__engram__.mem_context(project="Amira Writer")` for the latest observations.
4. Do not re-explore everything. Resume from **Next Best Steps**, likely:
   - add `/image-intelligence/smoke` loopback endpoint,
   - or run next capped multi-image/reference-selection smoke test,
   - or start the script UI direction/action/camera migration if Gary asks for UI work.
