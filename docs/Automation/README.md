# Amira Automation Pipeline

This folder tracks the safe implementation plan for the prompt-to-animated-footage automation pipeline described in `amira_automation_strategy_packet`.

## Standing guardrails

- The app stays local-folder-first. Do not use or revive the deprecated Novotro Project Server.
- Phase 0/1 automation is dry-run only: it may read project data and write sidecar planning artifacts, but it must not call paid image/video providers.
- Existing manual Animate workflows remain intact. Do not remove or overwrite user text, references, generated assets, approvals, or QA results.
- `Places/places-world-context.json` is canonical for time period/world context. Stale duplicate files elsewhere must not override it.
- Paid generation phases must require an explicit execute mode, cost caps, sidecar records, and resumable visible job state.

## Phase 0/1 slice implemented first

The first app-facing slice starts from existing `Scenes/scenes.json` and produces artifact-backed planning data:

```text
Scenes/scenes.json
→ EffectiveShotSpec
→ ReferenceContract
→ ShotFrameGenerationPlanSet
→ dry-run cost/blocker report
```

No transcript import, image generation, video generation, or QA repair loop should be implemented before this dry-run path is working and easy to inspect.

## Artifact locations

Planning artifacts are written inside the live project so they are durable and manually editable:

```text
Animate/shot-specs/<sceneID>/<shotID>.json
Animate/reference-contracts/<sceneID>/<shotID>.json
Animate/shot-frame-plans/<sceneID>/<shotID>.json
Animate/shot-frame-plans/DryRuns/automation-frame-plans-latest.json
Metadata/automation/minimax-scaffolds/<sceneID>/<artifactID>/
  prompt.txt
  response.txt        # execute mode only
  scaffold.json
```

Future phases will add:

```text
Metadata/automation/transcript-imports/
Animate/generated-frames/
Animate/video-tasks/
```

The first Phase 2 scaffold writes generated-frame run records to:

```text
Animate/generated-frames/<sceneID>/<shotID>/<beginning|middle|end>-latest.json
```

Generated PNGs and provider sidecars continue to use the existing Imagine storage convention:

```text
Animate/Imagine/scenes/<scene-slug>/shot-###/<beginning|middle|end>/
  *.png
  *.prompt.txt
  *.response.txt
  *.plan.json
```

## Loopback API

The Animate loopback API (`127.0.0.1:19849`) owns these dry-run endpoints:

```http
GET  /automation/project/summary
GET  /automation/shots/{shotID}/effective-shot-spec
GET  /automation/scenes/{sceneID}/effective-shot-specs
POST /automation/references/resolve
GET  /automation/references/{sceneID}/{shotID}
POST /automation/frame-plans/dry-run
POST /automation/minimax/scaffold
POST /automation/frames/generate
GET  /automation/generated-frames/{sceneID}/{shotID}/{moment}
POST /automation/generated-frames/{sceneID}/{shotID}/{moment}/approval
```

`POST /automation/frame-plans/dry-run` accepts a body like:

```json
{
  "scene": "first",
  "model": "nano-banana-2",
  "imageSize": "4K",
  "write": true,
  "maxCostUSD": 25.0
}
```

The response includes the sidecar report path, effective specs, reference contracts, generated plan sets, estimated Vertex cost, and blockers. It performs zero paid generation.

`POST /automation/minimax/scaffold` is the optional cheap LLM scaffolding layer. It is designed for MiniMax M2.7's strengths and weaknesses: the app supplies an explicit schema, scene facts, shot specs, reference roles, and available Image Intelligence captions/tags; MiniMax is asked to return strict JSON continuity data, not freeform prompts. Dry-run mode writes the prompt package for inspection and performs zero provider calls:

```json
{
  "mode": "dry_run",
  "scene": "first",
  "model": "MiniMax-M2.7",
  "write": true
}
```

Execute mode is opt-in with `"mode":"execute"` and writes `prompt.txt`, `response.txt`, and `scaffold.json` under `Metadata/automation/minimax-scaffolds/`. The resulting scaffold is advisory and must pass deterministic validation before it is allowed to influence paid image generation.

`POST /automation/frames/generate` defaults to no-spend preflight mode. Preflight returns planned `GeneratedFrameRecord` payloads for inspection but does not write generated-frame records or call Gemini:

```json
{
  "mode": "preflight",
  "scene": "first",
  "moments": ["beginning"],
  "model": "nano-banana-2",
  "imageSize": "4K",
  "maxCostUSD": 25.0,
  "maxFrames": 12
}
```

Paid generation is intentionally gated. It only runs when `mode` is exactly `execute`, Gemini generation is enabled, and `maxCostUSD` is present and high enough for the planned frame count. Execute mode writes a generated-frame record before each provider call, then updates it with output/prompt/response/plan sidecar paths after success or a visible failure state after error. Beginning/middle/end plans still use 4:3 open-matte generation with the configured 16:9 extraction / 21:9 final-delivery crop metadata.

Continuity behavior is conservative: beginning frames can generate from references; middle/end frames may edit from a readable prior generated frame when the plan resolver can see one. If continuity requires an edit source and none exists, the frame record is blocked with `blocked_missing_edit_source` instead of silently paying for a disconnected generation.

Generated-frame approvals are durable and local. The approval endpoint updates the generated-frame record sidecar and can optionally sync with existing manual review surfaces:

- approved frames can be set as the selected beginning/middle/end frame in `Animate/Imagine/galleries.json`
- rejected frames can be marked rejected in the image `.xmp` sidecar and cleared if they were selected
- approval does not run generation, video upload, or QA

## Reference status behavior

`ReferenceContract` sidecars are intentionally durable. If a user or later UI marks a reference as `pinned`, reruns preserve it. If a reference is marked `rejected`, reruns do not return it as an automatic candidate.

## Image review feedback memory

The All Images details inspector now treats the existing **Notes** field as structured plain-text feedback. When a reviewed image has notes, a rating, or a rejected flag, the app writes a project-local feedback artifact under:

```text
Metadata/automation/image-feedback/
```

Each artifact includes the image path, source/group context, rating/rejection state, notes, and the latest Image Intelligence caption/entities/scene/camera/style/retrieval JSON when available. Dry-run shot-spec building reads these feedback artifacts by simple relevance matching and injects matching notes into the prompt as "Review feedback memory" so repeated corrections such as bridge/ravine geography or Johnny's Polaroid satchel can influence future generations without editing the original prompt by hand.

### Fast review keys

When the Details → Notes field is focused:

```text
[  previous image
]  next image
/  reject current image and advance
?  reject current image and advance
\  reject current image and advance
;  mark current image five stars and advance
:  mark current image five stars and advance
```

The All Images grid/filmstrip also recognizes the same review keys when it has keyboard focus.

### Parakeet review dictation

The microphone button in the All Images details inspector starts a project-local review-dictation segment. Audio chunks are stored under:

```text
Metadata/automation/review-dictation/
```

On each review key, the app stops the current segment, tries to transcribe it, appends the transcript to Notes, performs the review action, and starts a new segment if dictation is still enabled.

Configure Parakeet with either an executable script at:

```text
Scripts/parakeet-transcribe.sh
```

or a project-local settings file:

```json
{
  "commandTemplate": "/path/to/parakeet-transcribe --audio {audio}"
}
```

saved as:

```text
Settings/parakeet-review-dictation.json
```

The command must print the transcript to stdout. This keeps transcription project-local and avoids any paid provider call.

## Canvas Prompt Generator and review feedback memory

The old guided trainer workspace has been removed from the active app. Visual preference learning now comes from the simpler All Images review flow plus the Canvas Prompt Generator:

- Rate, like, reject, recategorize, and note images in All Images; those project-local sidecars feed prompt-memory and continuity-rule extraction.
- Use the Canvas Prompt Generator under Canvas reference images to turn plain-English intent into a clean Gemini prompt using MiniMax plus rated/non-rejected reference selection.
- Continuity rules are promoted from All Images review notes and Image Intelligence metadata under `Metadata/automation/continuity-rules/`.
- Generated/edit outputs should preserve their semantic review scope so character images do not train or appear as place/map images.

Useful local API checks:

```bash
curl -sS -X POST http://127.0.0.1:19849/automation/feedback/rules/extract \
  -H 'Content-Type: application/json' \
  -d '{"mode":"dry_run","maxSources":80,"write":true}' | jq

curl -sS -X POST http://127.0.0.1:19849/automation/feedback/rules/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"bridge ravine town river north bank","limit":5}' | jq
```

Design intent:

- Keep training generations cheap (`1K`, `4:3` open matte) with explicit execute mode and cost caps.
- Use guided pathways in priority order: world geography → bridge/ravine → place topography → character identity → costume/accessory → style continuity.
- Preserve all existing workflows; this adds a new artifact-backed feedback layer instead of mutating `Scenes/scenes.json`, place records, or character rigs.
