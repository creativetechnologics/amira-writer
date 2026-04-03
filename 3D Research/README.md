# 3D Research

Date: 2026-04-01

This folder is an isolated research track for exploring whether **Amira** can move from mostly 2D/generated-animation workflows toward a **3D world + 3D character + cel-shaded final look** pipeline, with **Amira Writer itself as the primary authoring and runtime environment**.

## Guardrails

- Do **not** modify the Amira Writer app code from this research track.
- Do **not** create accounts.
- Do **not** call paid APIs or paid model endpoints.
- Prefer open or source-available tools first.
- Treat **Mac M4 / 16 GB unified memory** as the baseline local machine.
- Treat **RunPod / cloud GPUs** as later-stage evaluation only when clearly justified.
- Prefer an **Amira-native engine** over a Blender-centered workflow.

## Current thesis

The strongest path is an **Amira-native hybrid stack**, not one model:

1. **Scene/world generation** for broad layout and spatial exploration
2. **Asset generation/reconstruction** for bridge, buildings, props, rocks, trees
3. **Motion generation** for body acting / locomotion
4. **Dedicated mouth / facial layer** for lip sync and expressive control
5. **Amira-native 3D runtime** for scene graph, cameras, lights, playback, and review
6. **Cel shading inside the Amira runtime**
7. **Shot package interchange** so Animate-style direction maps cleanly into 3D

## First-pass recommendation

### Best scene/world candidates
- **HunyuanWorld** — strongest Tencent world-model direction for explorable 3D worlds
- **Matrix-3D** — strong open scene-scale option for panoramic/explorable world generation
- **MIDI-3D** — especially relevant if Amira concept art can be segmented into scene instances

### Best asset candidates
- **Hunyuan3D-2.1** — strongest source-available asset-generation candidate
- **TRELLIS** — very strong quality for assets, but Linux/NVIDIA-heavy
- **Stable Fast 3D** — most promising lighter-weight local asset sanity check

### Best motion candidates
- **HY-Motion-1.0** — strongest Tencent text-to-motion match
- **PantoMatrix** — compelling speech-to-body/face bridge
- **LivePortrait / LatentSync** — strongest early face/lip feasibility candidates

### Best authoring/runtime stack
- **Amira Writer + RealityKit** first
- **USD** as canonical scene-package/interchange layer
- **Blender** only as optional fallback for asset cleanup if absolutely needed
- **Unreal** as optional premium/offload path later if RealityKit hits a ceiling

## Folder map

- `docs/01-model-landscape.md`
  - ranked model/tool landscape
- `docs/02-toolchain-and-runtime.md`
  - Amira-native RealityKit/USD toolchain recommendation
- `docs/03-feasibility-and-experiment-plan.md`
  - local-vs-cloud feasibility and no-cost experiment ladder
- `docs/04-3d-shot-pipeline.md`
  - future architecture and mapping from Animate concepts
- `docs/05-amira-native-realitykit-engine.md`
  - proposed in-app 3D engine architecture
- `docs/06-llm-command-dsl.md`
  - LLM-facing command model for 3D direction
- `docs/07-animate-to-3d-integration.md`
  - concrete reuse points from current Animate architecture
- `docs/08-realitykit-style-and-rendering.md`
  - RealityKit-first cel-shaded rendering strategy
- `docs/09-implementation-program.md`
  - phased build program for the Amira-native engine
- `docs/10-review-and-apply-preview.md`
  - preview-first review/apply model for the 3D engine
- `docs/11-lighting-and-atmosphere-system.md`
  - native light/time-of-day/atmosphere architecture
- `docs/12-performance-and-asset-rules.md`
  - RealityKit-oriented constraints and intake rules
- `notes/local-environment-2026-04-01.md`
  - current local machine observations
- `scaffolding/shot-package/`
  - draft 3D shot-package scaffold
- `scaffolding/asset-registry/`
  - draft environment/asset registry scaffold
- `scaffolding/command-dsl/`
  - draft 3D command-plan scaffold
- `scaffolding/runtime-graph/`
  - draft scene/world/runtime state scaffold
- `scaffolding/world-catalog/`
  - draft Amira-specific world/preset registry
- `scaffolding/style-profiles/`
  - draft style profile schema
- `scaffolding/camera-presets/`
  - draft camera preset schema
- `scaffolding/character-registry/`
  - draft character registry schema
- `scaffolding/review-preview/`
  - draft 3D apply-preview schema
- `scaffolding/light-rigs/`
  - draft light rig schema
- `scaffolding/atmosphere-presets/`
  - draft atmosphere preset schema
- `scaffolding/motion-registry/`
  - draft motion registry schema
- `scaffolding/viseme-mapping/`
  - draft mouth/blendshape mapping schema
- `experiments/experiment-log.md`
  - running experiment queue and status

## Immediate next experiments

1. **Amira-native RealityKit scene proof**
2. Draft the **3D command DSL**
3. Draft the **runtime scene graph / state model**
4. Draft the **camera/style/character preset registries**
5. **One image → one 3D asset** benchmark with a local/no-cost candidate
6. **One line of dialogue → face/lip reference motion** benchmark

## Starting verdict

This is **feasible**, but only as a **modular Amira-native pipeline with deterministic runtime systems**, not as a one-click world generator.
