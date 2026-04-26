# 08 — Implementation Roadmap and Task Breakdown

## Recommended first build sequence

1. Canonical source resolver.
2. EffectiveShotSpecBuilder.
3. ReferenceContractResolver.
4. Scene dry-run report.
5. ShotFramePlanBuilder.
6. One-shot frame generation.
7. Frame approval.
8. Vidu queue.
9. Frame/video QA.
10. Transcript import.

Do not start with five-hour dictation. Start with existing `Scenes/scenes.json`, because the live project already has 367 shots and 51/52 scenes mapped to places. That gives immediate leverage while building the same machinery the dictation importer will later use.

---

## Phase 0 — Normalize repo/base state

Goal: choose a safe implementation base before coding.

Tasks:

1. Confirm whether to build from `main` or recent feature branch `codex/integrate-morning-slices-20260426-104613`.
2. Preserve recent branch work around Image Intelligence, shot-frame dry-runs, open-matte planning, storyboard links, and API extensions.
3. Add a repo doc stating canonical data sources.
4. Add a guardrail test that rejects stale mid-2020s world context.

Acceptance tests:

- App opens the local project without Novotro Project Server.
- Scene count reads 52.
- Shot count reads 367.
- Place count reads 27.
- World period resolves to early 2000s.
- No automation reads stale `Animate/places-world-context.json`.

---

## Phase 1 — Dry-run-only automation

Goal: produce useful planning reports without spending money.

Build:

1. `EffectiveShotSpecBuilder`
2. `ReferenceContractResolver`
3. `ShotFramePlanDryRunService`
4. Scene-level dry-run report API
5. UI preview panel or JSON report viewer

Outputs:

```text
effective-shot-specs.json
reference-contracts.json
frame-plan-dry-run.json
ambiguity-report.json
cost-estimate.json
```

Acceptance tests:

- Dry-run one scene with zero image/video generation.
- A scene with `backgroundID` includes the approved place image.
- Outdoor shots include map reference when geography matters.
- Bridge shots include bridge references plus map reference.
- Focus-character shots include the correct character package refs.
- Pinned refs survive resolver re-run.
- Rejected refs do not return automatically.

---

## Phase 2 — One-shot and one-scene frame generation

Goal: generate approved start/end frames safely.

Build:

1. Generate beginning frame for one shot.
2. Generate middle/end through edit mode when continuity is important.
3. Fall back to fresh generation for hard cuts, location changes, or time jumps.
4. Store sidecars for every generated frame.
5. Add frame approvals and selected variant tracking.
6. Expand to one-scene resumable queue.

Acceptance tests:

- Beginning frame can be generated from a dry-run plan.
- Middle/end use beginning frame as edit source when appropriate.
- Hard-cut/new-location shot forces generate mode.
- Every paid frame job writes `prompt.txt`, `response.txt`, `plan.json`, refs, status, and output path.
- Shot cannot move to video queue without approved start/end frames.

---

## Phase 3 — Video task queue

Goal: hand off approved start/end frames to Vidu or another provider.

Build:

1. Local frame upload/public URL strategy.
2. `VideoTaskRecord` sidecars.
3. Vidu queue action.
4. Poll/download action.
5. UI status list.
6. Failure/resume handling.

Acceptance tests:

- Video task cannot queue without approved start/end frames.
- Task record includes provider, model, URLs, prompt, duration, status, output path, attempt.
- Polling resumes after app restart.
- Failed tasks remain visible and retryable.
- Downloaded output is stored inside the project.

---

## Phase 4 — QA and correction loop

Goal: automate quality checks without hiding failures.

Build:

1. Frame analysis using existing Image Intelligence/Gemini/Vertex path.
2. QA comparison against `EffectiveShotSpec` + `ReferenceContract`.
3. Targeted correction prompt generator.
4. Retry policy.
5. Manual escalation.

Acceptance tests:

- QA flags missing character.
- QA flags wrong place.
- QA flags wrong time-of-day.
- QA flags style drift.
- QA flags wrong bridge/map geography.
- After retry cap, job becomes `needs_manual_review`.

---

## Phase 5 — Dictation/STT-to-shot-spec import

Goal: turn long spoken descriptions into proposed shot updates.

Build:

1. Transcript import folder.
2. Transcript segmentation.
3. LLM output schema validation.
4. Known character/place matching.
5. New place/character candidate handling.
6. Ambiguity report.
7. “Apply to scene store” command with preview.

Acceptance tests:

- Long transcript imports without mutating scenes.
- Existing character slugs match known packages.
- Unknown character becomes `new_character_candidate`.
- Unknown geography becomes `new_place_candidate`.
- Ambiguous place is not silently attached to a nearby place.
- User can apply selected shot specs to `Scenes/scenes.json`.

---

# Isolated coding tasks

## Task group A — Repo and canonical source cleanup

### A1. Add canonical source resolver

Scope:

- Read project root.
- Resolve:
  - `Scenes/scenes.json`
  - `Places/places.json`
  - `Places/places-world-context.json`
  - `Characters/*/rig.json`
  - `Settings/animated-look-prompt.json`

Tests:

- Returns 52 scenes, 367 shots, 27 places for live project.
- Uses early-2000s world context.
- Does not read deprecated server paths.

### A2. Add automation docs

Scope:

- Add the docs in this packet to `Docs/Automation`.
- No app behavior change.

Tests:

- Docs exist.
- Docs mention local-folder-first.
- Docs mention dry-run-first.
- Docs mention manual intervention.

## Task group B — Data contracts

### B1. Add Codable models

Suggested file:

```text
Packages/Animate/Sources/AnimateUI/Models/AutomationModels.swift
```

Models:

- `TranscriptImport`
- `TranscriptShotSpec`
- `EffectiveShotSpec`
- `ReferenceContract`
- `ShotFrameGenerationPlan`
- `GeneratedFrameRecord`
- `VideoTaskRecord`
- `QAResult`

Tests:

- JSON decode/encode round trip.
- Missing optional fields decode safely.
- Missing required IDs fail validation.

### B2. Add validation service

Service:

```swift
ShotSpecValidationService
```

Tests:

- Unknown character slug is flagged.
- Unknown place is flagged.
- New place candidate is allowed but blocked from generation.
- Video queue blocked without approved start/end frames.

## Task group C — Effective shot specs

### C1. Build `EffectiveShotSpecBuilder`

Inputs:

- `AnimationScene`
- `AnimationSceneShot`
- places index
- characters index
- world context
- animated look prompt

Output:

- `EffectiveShotSpec`

Tests:

- Scene `backgroundID` resolves to place.
- `focusCharacterSlug` resolves to character package.
- World period is early 2000s.
- Missing background produces `needs_review`.

### C2. Add API endpoint

Endpoint:

```http
GET /automation/shots/{shotID}/effective-shot-spec
```

Tests:

- Returns valid JSON.
- Includes place and character fields.
- Does not mutate project files.

## Task group D — Reference contracts

### D1. Add `ReferenceContractResolver`

Inputs:

- `EffectiveShotSpec`
- Image Intelligence selector
- places
- characters
- reference registry
- manual overrides

Outputs:

- `ReferenceContract`

Tests:

- Known place includes approved image.
- Outdoor shot includes map.
- Bridge shot includes bridge refs.
- Focus character includes identity ref.
- Max 8 refs respected with quotas.

### D2. Add pin/reject persistence

Files:

```text
Animate/reference-contracts/<scene>/<shot>.reference-contract.json
```

Tests:

- Pinned ref survives rerun.
- Rejected ref does not reappear.
- Rejection reason is stored.

### D3. Add reference API

Endpoints:

```http
POST /automation/references/resolve
GET /automation/references/{sceneID}/{shotID}
POST /automation/references/{sceneID}/{shotID}/pin
POST /automation/references/{sceneID}/{shotID}/reject
```

Tests:

- Dry-run returns contract without writing.
- Save mode writes sidecar.
- Pin/reject updates sidecar.

## Task group E — Frame plan dry-runs

### E1. Add `ShotFramePlanBuilder`

Inputs:

- `EffectiveShotSpec`
- `ReferenceContract`
- existing approved frames
- storyboard refs
- adjacent shot context

Output:

- `ShotFrameGenerationPlan`

Tests:

- First frame mode is `generate`.
- End frame mode is `edit` when source exists and continuity applies.
- New place/hard cut forces `generate`.
- Missing edit source blocks visibly.
- Prompt includes period, region, materials, lighting, tone.

### E2. Add dry-run report for scene

Endpoint:

```http
POST /automation/frame-plans/dry-run
```

Tests:

- Full scene report generated.
- No paid generation.
- Blockers listed.
- Cost estimate included.

## Task group F — Frame generation queue

### F1. Wire plan-driven frame generation

Use existing:

- `GeminiImageService`
- `ImagineGenerationService`
- sidecar writing pattern

Tests:

- Generated image writes prompt/response/plan sidecars.
- Variant metadata stored.
- Job status visible.

### F2. Add approvals

Data:

```json
{
  "approvedVariantID": "...",
  "approvedAt": "ISO-8601",
  "approvedBy": "user"
}
```

Tests:

- User can approve beginning.
- User can approve end.
- Video remains blocked until both are approved.

## Task group G — Video handoff

### G1. Add `VideoTaskRecord`

Tests:

- Record encodes/decodes.
- Record survives app restart.

### G2. Implement local-frame upload/public URL strategy

Tests:

- Upload failure blocks video queue.
- Public URL saved.
- Local path preserved.

### G3. Wire Vidu queue/poll/download

Tests:

- Queue task from approved frames.
- Poll updates status.
- Download stores output.
- Failed status is retryable.
- App restart can resume polling from sidecar.

## Task group H — QA

### H1. Frame QA service

Tests:

- Missing character flagged.
- Wrong place flagged.
- Wrong time period flagged.
- Wrong style flagged.

### H2. Correction prompt generator

Tests:

- Wrong place correction emphasizes approved place ref.
- Wrong character correction emphasizes identity/costume refs.
- Retry count increments.
- Retry cap triggers manual review.

## Task group I — Dictation import

### I1. Add transcript import artifact writer

Tests:

- Import creates folder under `Metadata/automation/transcript-imports`.
- No mutation to `Scenes/scenes.json`.

### I2. Add LLM output validator

Tests:

- Known place matches.
- Unknown place becomes candidate.
- Known character slug matches.
- Unknown character becomes candidate.
- Ambiguous focus blocks auto-apply.

### I3. Add apply flow

Tests:

- Preview shows changes.
- Apply writes changes.
- Re-run preserves manual overrides.
