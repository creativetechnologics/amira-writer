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
POST /automation/frames/generate
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

## Reference status behavior

`ReferenceContract` sidecars are intentionally durable. If a user or later UI marks a reference as `pinned`, reruns preserve it. If a reference is marked `rejected`, reruns do not return it as an automatic candidate.
