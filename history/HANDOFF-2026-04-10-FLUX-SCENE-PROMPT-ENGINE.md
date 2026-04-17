# Amira Writer Handoff — FLUX Scene Prompt Engine / Multi-Character LoRA Binding

Date: 2026-04-10  
Workspace: `/Volumes/Storage VIII/Programming/Amira Writer`

## Goal

Improve scene prompting for FLUX.2 [klein] so multi-character Draw Things generations respect:

- who is who
- left/right blocking
- per-character actions
- newer random trigger-token LoRAs

## What Changed

### 1) Character trigger words now bind inline to the right names

Previous behavior:

- applicable trigger words were prefixed at the front of the prompt
- this was weak for multi-character scenes because the prompt did not bind each token to a specific character/action clause

New behavior:

- trigger words are injected inline beside the matched character name token
- if the trigger already equals the visible name token (for example `luke`), no duplicate token is added
- if no name token is found, the old prefix fallback remains

Primary file:

- `Packages/Animate/Sources/AnimateUI/Services/DrawThingsLoRAService.swift`

### 2) Auto scene prompting now targets FLUX-style front-loaded prompts

`ImagineScenePromptService` now instructs GPT 5.4 to output:

1. named characters + blocking + action first
2. camera/composition second
3. setting/light third
4. photoreal guardrails last

This is intentionally shorter and more blocking-focused than the earlier prose-heavy prompt style.

Primary file:

- `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift`

### 3) Scene generation now honors Draw Things prompt prefix/suffix

Imagine scene generations now pass through the configured Draw Things prompt prefix/suffix before LoRA preparation, so global house-style controls apply to scene prompts too.

Primary file:

- `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`

### 4) Scene model defaults now match the current FLUX setup

- removed the old Z-Image option from the scene model enum
- removed `Flux.2 Klein 4B` from scene generation for now
- `Flux.2 Klein 9B` is now the only scene-generation model exposed in the Imagine scene workflow
- legacy saved `z_image_turbo` and `flux2_klein_4b` values decode forward to `Flux.2 Klein 9B`

Primary files:

- `Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateAutomation.swift`

### 5) Scene prompt editing is now vertically resizable

- added a draggable horizontal resize handle above the Draw Things / Gemini generator controls
- the scene prompt editor can now be resized vertically in-place inside Imagine > Scenes
- bulk scene controls no longer depend on a stale MiniMax API-key gate now that scene auto-prompting uses GPT 5.4

Primary files:

- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift`

### 6) Prompt recipes and workflow notes were documented

Added a dedicated spec doc with:

- FLUX multi-character prompt formula
- Luke + Matt trial prompts
- recommended weight starting points
- environment/style LoRA guidance
- clarification that the Imagine scene **Pre-fill** action is a local heuristic template, not an LLM-generated prompt

Files:

- `docs/specs/2026-04-10-flux-scene-prompt-engine.md`

### 7) Draw Things LoRA sync now updates the custom LoRA registry

Root cause discovered from a live failure:

- the app was copying synced LoRA files into Draw Things' models folder
- but it was **not** registering those copied files in Draw Things' `custom_lora.json`
- Draw Things then rejected generation requests with a “Missing file” error even when the `.safetensors` file was physically present on disk

Fix implemented:

- whenever Amira Writer syncs a LoRA into Draw Things, it now also inserts or updates the matching `custom_lora.json` entry
- the registry version is inferred from the active Draw Things model metadata when available, with a FLUX.2 9B fallback heuristic for the current scene workflow
- this keeps the imported filename and Draw Things’ known-file registry in sync

Primary files:

- `Packages/Animate/Sources/AnimateUI/Services/DrawThingsLoRAService.swift`
- `Packages/Animate/Tests/AnimateTests/DrawThingsLoRAServiceTests.swift`

## Validation

### Build

Remote server build succeeded:

- `swift build -c release --package-path /Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate`

### App bundle deploy

Built and installed:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Verified timestamps:

- App bundle: `2026-04-10 18:34:03 PDT`
- Binary: `2026-04-10 18:34:04 PDT`

### Tests

New targeted tests were added for:

- inline trigger injection
- legacy model-value migration

However, `swift test` for the Animate package is currently blocked by **pre-existing unrelated compile failures** across `Animate3DTests` (missing 3D symbols / registries). The scene-prompt work itself did not introduce those failures.

## Recommended Next Steps

1. In the app, test Luke + Matt scene generation with the new inline trigger binding.
2. If exact left/right still drifts, add a two-stage workflow:
   - txt2img for composition discovery
   - img2img/edit from the chosen frame
3. Add an environment/style LoRA path for recurring clinic-street looks.
4. If desired, expose a small “blocking template” UI preset for:
   - two-shot confrontation
   - one standing / one kneeling
   - screen-left / screen-right lock
