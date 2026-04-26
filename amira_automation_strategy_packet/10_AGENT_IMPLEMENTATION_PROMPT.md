# 10 — Agent Implementation Prompt

You are a coding agent working in the Amira Writer repo.

Your job is to implement the prompt-to-animated-footage automation pipeline in small, safe, testable phases.

## Project context

App repo:

```text
/Volumes/Storage VIII/Programming/Amira Writer
```

Live project:

```text
/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera
```

Canonical app modules:

```text
Sources/Opera
Sources/WriteUI
Packages/Animate/Sources/AnimateUI
Packages/ProjectKit
Packages/Score
```

Canonical live project sources:

```text
Songs/*.ows
Scenes/scenes.json
Places/places.json
Places/places-world-context.json
Characters/*/rig.json
Settings/animated-look-prompt.json
Animate/reference-registry.json
Animate/reference-registry.md
```

## Hard rules

1. The app is local-folder-first.
2. Do not use or revive the deprecated Novotro Project Server.
3. Preserve manual intervention at every step.
4. Prefer dry-run/report-first workflows before any paid image/video generation.
5. Do not rely on the project title as visual shorthand.
6. Prompts must spell out time period, regional/world cues, architecture/materials, lighting, camera/framing, and visual tone.
7. `Places/places-world-context.json` is canonical for world period.
8. Ignore stale duplicate world-context files that say mid-2020s.
9. Do not silently overwrite user text, references, generated assets, approvals, or QA results.
10. Every paid generation job must write sidecars and remain resumable.

## Current live-data assumptions to validate

Before implementation, add or run a project summary check:

```text
Scenes: 52
Shots: 367
Places: 27
Songs: 52 .ows files
Character rig folders with rig.json: 6
Scenes with backgroundID: 51 / 52
Shots with populated shotFrameGeneration: 0
Shots with populated shotBackgroundPlate: 0
```

If the current checkout differs, report the difference rather than forcing these values.

## Branch warning

The packet says the recent feature branch may contain important work that is not on `main`:

```text
codex/integrate-morning-slices-20260426-104613
```

Recent work may include:

```text
ShotFrameGenerationPlan / resolver / dry-run planner
Open-matte crop planning
Storyboard frame analysis sidecars
Image Intelligence links
Animate API extensions
Right-click spatial character tagging
```

First, inspect the repo and decide whether to build from the current branch, merge the feature branch, or port the needed pieces. Do not discard useful recent work.

## North-star pipeline

Implement toward this architecture:

```text
dictated/written visual brief
→ transcript import
→ TranscriptShotSpec[]
→ validation and ambiguity report
→ EffectiveShotSpec
→ ReferenceContract
→ ShotFrameGenerationPlan
→ generated beginning/end frames
→ frame QA and approval
→ VideoTaskRecord
→ video QA and repair
→ approved footage
```

Every stage must expose a durable artifact and a manual override point.

## First implementation target

Do not start with five-hour dictation. Start with existing `Scenes/scenes.json`.

The first useful target is a dry-run scene report that produces:

```text
EffectiveShotSpec
ReferenceContract
ShotFrameGenerationPlan
cost/blocker report
```

No paid image/video generation should happen in Phase 1.

## Phase 0 tasks

1. Add a canonical source resolver.
2. Add docs under `Docs/Automation` using this packet.
3. Add a project summary/check command or endpoint.
4. Add guardrails that read `Places/places-world-context.json`.
5. Ensure deprecated server paths are not used.

Acceptance:

```text
- app opens local project
- project summary can read scenes/shots/places/characters
- world period resolves to early 2000s
- stale mid-2020s duplicate is ignored
```

## Phase 1 tasks: dry-run-only automation

Implement:

```swift
EffectiveShotSpecBuilder
ReferenceContractResolver
ShotFramePlanBuilder
ShotSpecValidationService
```

Add loopback API endpoints:

```http
GET  /automation/project/summary
GET  /automation/shots/{shotID}/effective-shot-spec
GET  /automation/scenes/{sceneID}/effective-shot-specs
POST /automation/references/resolve
GET  /automation/references/{sceneID}/{shotID}
POST /automation/frame-plans/dry-run
```

Acceptance:

```text
- dry-run one scene with zero paid generation
- scene backgroundID resolves to approved place image
- outdoor shots include map ref when geography matters
- bridge shots include bridge refs plus map
- focus-character shots include correct character package refs
- pinned refs survive resolver rerun
- rejected refs do not return automatically
- frame plan prompts include world period, region, materials, lighting, camera, action, negative guardrails
```

## Phase 2 tasks: one-shot and one-scene frame generation

Use existing image generation services where possible:

```text
GeminiImageService
ImagineGenerationService
ImagineProjectStorage
```

Implement:

```text
- plan-driven beginning frame generation
- end frame generation/editing
- variant records
- frame approvals
- generated frame sidecars
- one-scene resumable queue
```

Acceptance:

```text
- beginning frame defaults to generate
- end frame uses edit when continuity applies
- hard cut/new location forces generate
- no readable edit source blocks visibly
- every paid job writes prompt.txt, response.txt, plan.json, refs/status/output path
- video queue blocks until approved start/end frames exist
```

## Phase 3 tasks: video handoff

Use existing `ViduAPIService`.

Implement:

```text
FrameUploadService protocol
VideoTaskRecord
video queue endpoint
poll endpoint
download endpoint
retry endpoint
UI task status or JSON report
```

Acceptance:

```text
- task cannot queue without approved start/end frames
- task record includes provider/model/URLs/prompt/duration/status/output/attempt
- task record is written before provider call
- polling/download resumes after app restart
- failed task remains visible and retryable
```

## Phase 4 tasks: QA and repair

Implement:

```text
FrameQAService
VideoQAService
CorrectionPromptBuilder
retry cap and manual-review escalation
```

Acceptance:

```text
- QA flags missing character
- QA flags wrong place
- QA flags wrong period/time-of-day
- QA flags wrong style
- QA flags wrong bridge/map geography
- after retry cap, job becomes needs_manual_review
```

## Phase 5 tasks: dictation/STT-to-shot-spec import

Implement after the existing scene pipeline works:

```text
TranscriptImport artifact writer
TranscriptShotSpec validator
known place/character matcher
new_place_candidate handling
new_character_candidate handling
ambiguity report
preview/apply flow
```

Acceptance:

```text
- long transcript imports without mutating Scenes/scenes.json
- known character slugs match known packages
- unknown character becomes new_character_candidate
- unknown geography becomes new_place_candidate
- ambiguous place is not silently attached to a nearby place
- user can preview and apply selected shot specs
```

## Required data contracts

Create versioned Codable models for:

```text
TranscriptImport
TranscriptShotSpec
EffectiveShotSpec
ReferenceContract
ShotFrameGenerationPlan
GeneratedFrameRecord
VideoTaskRecord
QAResult
```

Store artifacts inside the live project:

```text
Metadata/automation/transcript-imports/
Animate/shot-specs/
Animate/reference-contracts/
Animate/shot-frame-plans/
Animate/generated-frames/
Animate/video-tasks/
```

## Reference resolver requirements

Reference roles:

```text
location_identity
spatial_map
landmark_design
character_identity
character_costume
storyboard_layout
shot_continuity
style
manual_pinned
```

Priority order:

```text
1. manual pinned refs
2. same-shot storyboard/layout refs
3. same-shot approved frames
4. exact character/place refs by ID
5. hand-curated registry refs: map, bridge, costume
6. same scene/place/character generated refs
7. spatial character annotations
8. tags/metadata query matches
9. embedding similarity
10. style fallback refs
```

Max references are limited. Use role quotas, not just top scores.

## Shot-frame planning requirements

Use internal beginning/middle/end but video start/end handoff:

```text
beginning = start frame
middle = optional continuity/QA/split frame
end = end frame
```

Generate vs edit:

```text
- first frame usually generate
- same place/angle/characters edit from previous approved frame
- hard cut/new location/time jump generate
- storyboard frame can act as layout authority
- missing edit source must fail visibly
```

## API behavior requirements

- All dry-run endpoints must have zero paid generation.
- Paid endpoints require `mode: "execute"`.
- Cost caps must block oversized batches.
- Mutating endpoints must write sidecars.
- Queue jobs must be inspectable and resumable.
- Failure states must remain visible.

Use explicit error states:

```text
blocked_missing_place
blocked_missing_character
blocked_missing_reference_role
blocked_missing_edit_source
blocked_unapproved_start_frame
blocked_unapproved_end_frame
blocked_upload_failed
blocked_cost_cap
failed_provider_error
failed_qa
needs_manual_review
```

## Deliverable style

Work in small PR-sized chunks. Prefer isolated files/domains. For each chunk, provide:

```text
- files changed
- behavior added
- tests added
- commands run
- limitations/next tasks
```

Do not implement a broad paid-generation pipeline before the dry-run report is working and tested.
