# 07 — Animate-to-3D Integration Points

Date: 2026-04-01

## Goal

Identify which parts of the current Animate architecture should be:
- reused directly
- conceptually mirrored
- kept separate

for a future Amira-native 3D engine.

This document is based on inspection of the current Animate codebase, but it does **not** change app code.

---

## High-confidence reuse points

### 1. Structured plan input already exists
Current Animate already has a strong structured-plan pattern in:
- `Packages/Animate/Sources/AnimateUI/Models/LLMAnimationModels.swift`

That model already includes:
- `cameraMoves`
- `objectPlacements`
- `objectMotions`
- `objectStateCues`
- `dialogueBeats`
- `shotPresetApplications`

This means the future 3D engine does **not** need to invent its control philosophy from scratch.

Recommended direction:
- keep the same **structured plan → validate → preview → apply** philosophy
- introduce a 3D-specific sibling plan model rather than forcing all 3D semantics into the current 2D schema

Recommended future type:
- `LLM3DAnimationPlan`

---

### 2. The orchestration/review/apply pattern is already correct
Current orchestration entry point:
- `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneOrchestrationService.swift`

Concrete behaviors already present:
- plan review
- apply preview
- shot-slice preview
- resolved plan application
- warning aggregation

This is the exact product behavior the 3D engine should keep.

Recommended future sibling:
- `Amira3DSceneOrchestrationService`

Responsibilities:
- validate 3D commands
- resolve IDs against world/asset/style registries
- generate apply preview/diff
- emit runtime mutations

---

### 3. Camera logic already has a first-class place
Current signs:
- `cameraMoves` in `LLMAnimationPlan`
- camera-specific review/apply preview in orchestration
- camera cue editing in `AnimateStore`
- compiled camera tracks in `LLMAnimationPlanCompiler`

Relevant files:
- `Packages/Animate/Sources/AnimateUI/Models/LLMAnimationModels.swift`
- `Packages/Animate/Sources/AnimateUI/Services/LLMAnimationPlanCompiler.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

Recommended 3D direction:
- keep camera as first-class authored data
- replace 2D shot/cue semantics with:
  - camera entities
  - lens presets
  - focus targets
  - dolly/pan/orbit paths

---

### 4. Object placement/motion/state already matches 3D thinking
Current plan/compiler path already handles:
- object placements
- object motions
- object state cues

Relevant files:
- `Packages/Animate/Sources/AnimateUI/Services/AnimatePlanShotAnchorResolver.swift`
- `Packages/Animate/Sources/AnimateUI/Services/LLMAnimationPlanCompiler.swift`
- `Packages/Animate/Sources/AnimateUI/Models/LLMAnimationModels.swift`
- `Packages/Animate/Sources/AnimateUI/Models/SceneDirectionModels.swift`

This is extremely valuable because 3D scene authoring is largely:
- placement
- transform changes
- visibility/state toggles

Recommended future mapping:
- `objectPlacements` → asset/entity instancing in WorldGraph
- `objectMotions` → transform animation clips or scripted motion paths
- `objectStateCues` → style/state/material/visibility toggles

---

### 5. Mouth engine should remain separate
Current dedicated subsystem:
- `Packages/Animate/Sources/AnimateUI/Services/LipSyncEngine.swift`

Current integration points:
- Rhubarb analyzer path
- OWP lyric alignment generation
- mouth track application in `AnimateStore`

This separation is exactly right for 3D too.

Recommended future rule:
- do **not** merge mouth logic into the body-motion runtime
- keep mouth/viseme output as a separate track that targets:
  - blend shapes
  - jaw bones
  - mouth-control rigs

---

## High-confidence architectural mirrors

### 1. Workspace controller pattern
Current workspace shell:
- `Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift`

Pattern already present:
- workspace controller
- project load lifecycle
- selection restoration
- save indicator
- status messaging

Recommended future sibling:
- `Amira3DWorkspaceController`

Responsibilities:
- load world/asset registries
- load 3D shot packages
- maintain selected scene/shot/world state
- coordinate preview runtime

### 2. Store pattern
Current app state center:
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

The 3D branch will likely want either:
- a sibling `Amira3DStore`, or
- a more engine-focused state core under a separate package

Recommended rule:
- keep 3D runtime state separate from current 2D Animate store until contracts stabilize

---

## What should stay separate

### 1. 2D timeline internals
Do not force the first 3D runtime to pretend it is just another 2D timeline.

Reason:
- 3D scenes have persistent entity state
- world lighting and atmosphere are first-class
- camera and transform semantics are richer than 2D cue tracks

### 2. Current drawing/rig package assumptions
The existing character-package and drawing-selection assumptions are useful conceptually, but 3D characters will need:
- skeletal assets
- facial rig channels
- mouth/blend-shape mappings
- reusable motion clips

So:
- preserve the conceptual package pattern
- do not preserve every 2D asset assumption

---

## Recommended boundaries

### Boundary A — planning
LLM plan / command JSON only

### Boundary B — orchestration
validation, resolution, preview, diff

### Boundary C — runtime state
world graph, shot graph, performance graph, style graph

### Boundary D — renderer
RealityKit scene + native visual systems

### Boundary E — external workers
asset generation, world generation, motion generation, face/lip assist

---

## Initial implementation recommendation

The safest first implementation path is:

1. keep current Animate untouched
2. create a **parallel 3D engine package design**
3. mirror the plan/orchestration/review/apply pattern
4. reuse the mouth-engine philosophy directly
5. keep 3D scene/runtime state separate until the engine contract is stable

