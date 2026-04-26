# Storyboard Shot Intelligence Pipeline

**Date:** 2026-04-24
**Status:** Implementation plan + Phase 1 foundation
**Scope:** Script Direction/Action/Camera + iPad storyboard begin/middle/end frames + image-intelligence reference attachment.

## Goal

Make the script and iPad storyboard drawings cooperate as two source layers for automated beginning/middle/end frame generation:

- **Script** supplies semantic intent: who, where, what, why, dialogue/action/camera language.
- **Storyboard drawing** supplies visual intent: composition, blocking, scale, rough camera, visible movement, frame-to-frame layout.
- **Effective Shot Spec** fuses both into one production contract used for reference attachment, prompt generation, and QA.

## Authority Model

Field-level precedence:

1. Manual pinned override.
2. Semantic iPad anchors/chips.
3. High-confidence storyboard image/stroke analysis.
4. Script Direction plain-text visual description.
5. Script Action storyboarding/action text.
6. Script Camera DSL/camera text.
7. Scene defaults.
8. Project World Atlas defaults.

Storyboard drawings override only fields they positively assert. Absence in a rough sketch does not delete script entities unless the frame is marked authoritative or an explicit `not visible` anchor is added.

## Phase 1 — First-Class Storyboard Assets

**Build now.** Register saved iPad storyboard frames as Image Intelligence assets.

- Add `ImageAssetLinkKind.storyboardFrame`.
- Discover `Scenes/<sceneID>/storyboards/<shotID>/{begin,middle,end}.png`.
- Link with `ownerID = shotID`, `ownerParentID = sceneID`, `moment = begin|middle|end`.
- Store context: scene name, shot name, scene/shot order, source = iPad storyboard.
- Add ProjectPaths helpers for sidecars:
  - `<frame>.analysis.json`
  - `<frame>.strokes.json`
  - `<frame>.anchors.json`
- Keep the existing fast PNG save path non-blocking.

## Phase 2 — Analysis Sidecars

Create a `StoryboardFrameAnalysis` Codable sidecar that stores:

- image path, content hash, status, timestamps
- closed-world summary
- detected entities with bounding boxes/grid cells/confidence
- camera/framing read
- motion vectors/arrows
- visible text labels
- conflicts with script
- analysis backend/version metadata

On every iPad PUT save:

1. Save PNG immediately.
2. Write or update a pending analysis sidecar using file hash.
3. Enqueue image-intelligence analysis in the background if configured.
4. Never block the iPad response on AI analysis.

## Phase 3 — Closed-World Storyboard AI Analysis

Analyze drawings with known project context, not open-ended captioning.

Input context:

- scene and shot IDs/names
- frame moment begin/middle/end
- Direction/Action/Camera text
- known scene characters
- active place/background
- known landmarks and world geography
- prior analysis for sibling frames in same shot

Output strict JSON compatible with `StoryboardFrameAnalysis`.

## Phase 4 — Semantic iPad Anchors

Add optional machine-readable overlays to the iPad app:

- character chips
- place/landmark chips
- sun/time chip
- camera direction arrow
- motion arrow
- foreground/midground/background depth markers
- `not visible` and `authoritative layout` toggles

Persist to `<frame>.anchors.json`. These anchors outrank image-analysis guesses.

## Phase 5 — Script Shot Records + Effective Shot Spec

Create a parser/fusion pipeline:

`Direction/Action/Camera + storyboard analyses + anchors -> ShotVisualSpec -> ShotReferenceContract -> PromptPack`

The effective spec should keep field provenance so the UI can explain why a value won.

## Phase 6 — Reference Contract Resolver

Attach references using hybrid scoring:

- exact owner/ID match
- character/place/landmark role match
- tag match
- vector/semantic similarity
- visual metadata match
- approved/rated status
- rejection and wrong-angle penalties

Storyboard analysis provides composition and visual blockers; script/scene data provides exact identity and world continuity.

## Phase 7 — B/M/E Prompt Generation

Generate beginning/middle/end as one continuity-locked triad:

- shared reference contract
- shared world/lighting/camera continuity locks
- storyboard frame attached as layout control/reference for each moment
- generated beginning can condition middle/end where supported
- Gemini middle/end should prefer **edit prompts** from the closest generated in-shot source image when continuity is stronger than a full fresh generation.

### Gemini Generate-vs-Edit Strategy

Current implementation uses an explicit `ShotFrameGenerationPlan`:

- Beginning defaults to `generate`.
- Middle defaults to `edit` from the selected/newest beginning frame when available.
- End defaults to `edit` from the selected/newest middle frame, then falls back to beginning if middle is missing.
- Middle/end fall back to full `generate` when no source image exists or the target prompt indicates a hard cut/new angle/location/time jump.
- Target storyboard frames are attached as layout references for the same moment.
- Gemini edit requests send source/storyboard images before the text edit instruction, then persist `.prompt.txt`, `.response.txt`, and `.plan.json` next to the generated image.

This keeps the first frame strongly prompt/reference-driven while giving in-shot middle/end frames a continuity-preserving edit path.

## Phase 8 — QA Against Storyboard + Script

After image generation, analyze the result and compare to:

- storyboard analysis
- reference contract
- script spec
- world atlas

Regenerate with targeted corrections when required characters, landmarks, framing, time-of-day, or blocking drift.

## Phase 9 — One-Button Full-Show Generation

Only after Phases 1–8 are resumable:

1. Dry-run all shots.
2. Report missing assets/ambiguities.
3. Build a queue.
4. Generate shot triads scene-by-scene.
5. QA and retry.
6. Save selected outputs into the existing beginning/middle/end galleries.

## Immediate Safety Constraints

- Preserve existing script text as source of truth.
- Do not make image analysis mandatory for saving drawings.
- Do not infer deletion from absent sketch details by default.
- Keep all generated specs/analyses explainable and inspectable.
- Preserve manual overrides and rejected reference choices.
