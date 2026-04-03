# 05 — Amira-Native RealityKit Engine

Date: 2026-04-01

## Decision

Build the 3D branch so that **Amira Writer itself** becomes the main environment for:
- scene assembly
- camera direction
- lighting and time of day
- character playback
- mouth/face layering
- shot preview
- LLM-driven command authoring

The external models should act as **workers**, not as the user-facing app.

---

## Why this is viable

### 1. The existing Animate architecture already points this way
Current Animate already has:
- a structured `LLMAnimationPlan`
- `cameraMoves`
- `objectPlacements`
- `objectMotions`
- `objectStateCues`
- orchestration/review/apply services
- a dedicated `LipSyncEngine`

So the missing piece is not “LLM planning.”  
The missing piece is a **3D scene runtime** that those plans can target.

### 2. RealityKit is the right Apple-native renderer/runtime
Apple’s RealityKit overview says RealityKit 4 includes:
- blend shapes
- inverse kinematics
- skeletal poses
- animation timelines
- dynamic assets
- ECS-style custom systems

That is enough to justify a serious Amira-specific engine direction on macOS.

Apple also documents:
- loading entities from `.usd`, `.usda`, `.usdc`, `.usdz`, and `.reality` files
- imported animation playback through RealityKit’s animation systems
- post-processing and custom rendering hooks

That means the engine can stay Amira-native while still using USD-backed assets and imported motion where useful.

### 3. SceneKit should not be the long-term target
Apple now explicitly says SceneKit is deprecated and recommends RealityKit instead.

---

## Core principle

The **LLM is the director**, not the frame renderer.

The deterministic engine should own:
- scene graph state
- animation playback
- camera solving
- lighting
- style application
- reviewable diffs
- preview rendering

The LLM should emit:
- commands
- plans
- shot presets
- structured overrides

---

## Proposed runtime layers

### Layer A — WorldGraph
Amira-specific environment layer:
- valley terrain
- river spline / water body
- bridge
- town clusters
- trees, rocks, props
- sky / atmosphere profile

This layer should expose **stable IDs** instead of arbitrary scene-node names.

Example IDs:
- `world.valley.main`
- `world.river.main`
- `world.bridge.main`
- `world.town.cluster_a`

### Layer B — ShotGraph
Shot-state layer:
- active camera
- lens/framing preset
- shot timing
- dolly/pan/orbit/hold metadata
- focus target
- depth / composition hints

### Layer C — PerformanceGraph
Character and motion layer:
- character entities
- body motion tracks
- facial tracks
- mouth/viseme tracks
- gaze/blink/head-turn overlays

### Layer D — StyleGraph
Amira-specific visual layer:
- cel-shader profile
- outline profile
- fog/atmosphere profile
- color grade
- time-of-day preset

### Layer E — ReviewGraph
Diff/review layer:
- before/after command summary
- generated preview notes
- deterministic apply preview
- warnings about asset/motion/runtime mismatches

---

## Key RealityKit-specific architectural rule

Because Apple’s USD validation docs say RealityKit **doesn’t use lights embedded in USD files**, lighting should not be authored as imported USD truth.

Instead:
- geometry can arrive through USD
- skeletons can arrive through USD
- variants can arrive through USD
- but **lights, atmosphere, day/night state, and cel-shader style must be native Amira runtime systems**

This actually helps us, because Amira wants art-direction control anyway.

---

## What Amira should own directly

### Must be native
- camera system
- shot presets
- time of day
- lighting
- fog / haze / atmosphere
- cel shader / outline behavior
- mouth engine
- review/apply pipeline
- command DSL and plan compiler

### Can come from external workers
- world prototypes
- asset meshes
- character motion clips
- face/lip reference passes
- rough scene blockouts

---

## Product shape

This is not:
- a general-purpose 3D DCC
- a Blender replacement
- a universal game engine

This is:
- an **Amira-specific 3D direction engine**
- optimized for a small set of recurring locations, characters, and camera languages

That constraint is an advantage.

---

## Recommended build phases

### Phase 1 — Native scene runtime
- render one 3D scene in-app
- load one or more USD/USDZ assets
- attach Amira-native lighting/time-of-day/style controls
- basic camera entity and preview window

### Phase 2 — Command compiler
- translate LLM 3D plan JSON into runtime mutations
- support environment, camera, and object commands first

### Phase 3 — Character runtime
- add skeletal character entities
- support body animation clips
- support facial/mouth overlays

### Phase 4 — Review/apply workflow
- show diffs before commit
- allow stepwise application
- preserve deterministic scene state

### Phase 5 — External generation workers
- plug in scene, asset, motion, and face generators as background tasks
- map outputs into asset registry + shot package

---

## Sources

- RealityKit overview: https://developer.apple.com/augmented-reality/realitykit/
- SceneKit deprecation page: https://developer.apple.com/documentation/scenekit/
- WWDC25 migration guidance: https://developer.apple.com/videos/play/wwdc2025/288/
- Entity docs: https://developer.apple.com/documentation/realitykit/entity
- Entity loading: https://developer.apple.com/documentation/RealityKit/Entity/load%28named%3Ain%3A%29
- Postprocessing effects: https://developer.apple.com/documentation/realitykit/postprocessing-effects?changes=latest_minor
- USD feature validation: https://developer.apple.com/documentation/usd/validating-usd-files
- USD creation guidance: https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices
- RealityKit performance guidance: https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app
- RealityKit CPU guidance: https://developer.apple.com/documentation/realitykit/reducing-cpu-utilization-in-your-realitykit-app
