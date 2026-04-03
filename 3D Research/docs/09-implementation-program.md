# 09 — Implementation Program for the Amira 3D Engine

Date: 2026-04-01

## Goal

Turn the current research direction into a concrete build program, while keeping Amira Writer app code untouched for now.

---

## Program principle

Build the engine in layers, in this order:

1. **Runtime truth**
2. **Command truth**
3. **Render/style truth**
4. **Character truth**
5. **External worker truth**

If this order is reversed, the project risks becoming model-led instead of engine-led.

---

## Phase 0 — Contracts only

Current deliverables:
- shot package scaffold
- asset registry scaffold
- world catalog scaffold
- runtime graph scaffold
- 3D command DSL scaffold

Success condition:
- all major 3D concepts have stable IDs and draft schemas

Current files:
- `scaffolding/shot-package/examples/shot-package.example.json`
- `scaffolding/asset-registry/asset-registry.example.json`
- `scaffolding/world-catalog/world-catalog.example.json`
- `scaffolding/runtime-graph/examples/world-state.example.json`
- `scaffolding/command-dsl/examples/amira-3d-plan.example.json`

---

## Phase 1 — Runtime shell

Target:
- one Amira-native RealityKit preview surface

Responsibilities:
- load one world package
- load one camera preset
- apply one style profile
- show one preview scene

What this proves:
- Amira can become the control center
- RealityKit can be the base runtime

---

## Phase 2 — Command compiler

Target:
- transform 3D command-plan JSON into runtime mutations

Responsibilities:
- validate asset/world/style IDs
- build preview diff
- apply deterministic runtime mutations

Suggested future components:
- `LLM3DAnimationPlan`
- `Amira3DPlanCompiler`
- `Amira3DSceneOrchestrationService`
- `Amira3DApplyPreview`

---

## Phase 3 — World systems

Target:
- robust environment direction

Responsibilities:
- world variants
- time-of-day presets
- atmosphere/fog
- environment toggles
- asset placement and state changes

What this unlocks:
- valley/town/bridge staging before characters are fully live

---

## Phase 4 — Camera systems

Target:
- film-style camera direction

Responsibilities:
- lens presets
- camera cuts
- push/pan/orbit/track moves
- focus targets
- shot presets

What this unlocks:
- visually meaningful shot previews with no character complexity required yet

---

## Phase 5 — Character systems

Target:
- basic 3D acting

Responsibilities:
- character entity loading
- body motion clip playback
- motion-track binding
- scene-relative placement and facing

What this unlocks:
- blocking and movement

---

## Phase 6 — Face and mouth systems

Target:
- expressive dialogue and singing support

Responsibilities:
- viseme track application
- blend-shape mapping
- jaw/face overlays
- gaze and blink overlays

What this unlocks:
- the actual Amira performance language

---

## Phase 7 — External workers

Target:
- integrate model outputs without making them the center of the app

Responsibilities:
- import scene/world outputs
- import asset outputs
- import motion clips
- import face/lip assists
- normalize them into:
  - asset registry
  - world catalog
  - shot package

---

## Suggested future package layout

This is only a proposed layout, not an implementation change:

```text
Packages/
  Amira3DEngine/
    Sources/Amira3DEngine/
      Runtime/
      SceneGraph/
      Rendering/
      Camera/
      Performance/
      CommandDSL/
      Orchestration/
      AssetRegistry/
      WorldCatalog/
      ShotPackages/
```

---

## Recommended next documents to add

1. style profile schema
2. camera preset schema
3. character registry schema
4. motion clip registry schema
5. viseme/blend-shape mapping schema

These are the next most valuable scaffolds after the current batch.

