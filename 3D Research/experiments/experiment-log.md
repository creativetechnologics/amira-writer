# Experiment Log

Date opened: 2026-04-01

## Queue

### E-001 — Blender cel-shaded valley proof
- Status: replaced
- Goal: superseded by Amira-native runtime proof
- Inputs: one existing valley/town environment image
- Expected output: archived as fallback-only idea

### E-001A — Amira-native RealityKit scene proof
- Status: queued
- Goal: prove that an Amira-native 3D scene can load/display one environment package with native style and camera control
- Inputs: one small environment asset package
- Expected output: one in-app preview scene with camera + style controls

### E-002 — Single image to single bridge/building asset
- Status: queued
- Goal: judge whether existing artwork can become a usable 3D proxy
- Candidate tools: Stable Fast 3D, Hunyuan3D shape-only

### E-003 — Scene-scale concept-art to blockout world
- Status: queued
- Goal: determine whether one environment concept can become an explorable spatial blockout
- Candidate tools: Matrix-3D, HunyuanWorld, MIDI-3D

### E-004 — Facial / lip reference motion
- Status: queued
- Goal: determine whether AI facial motion can aid a future mouth/viseme layer
- Candidate tools: LivePortrait, LatentSync

### E-005 — 3D shot package contract
- Status: started
- Goal: define a future-neutral contract before any app integration
- Current artifact: `scaffolding/shot-package/examples/shot-package.example.json`

### E-006 — 3D command DSL contract
- Status: started
- Goal: define the reviewable LLM command surface for the Amira-native runtime
- Current artifact: `scaffolding/command-dsl/examples/amira-3d-plan.example.json`

### E-007 — Runtime graph contract
- Status: started
- Goal: define the minimum deterministic runtime state Amira must own directly
- Current artifact: `scaffolding/runtime-graph/examples/world-state.example.json`

### E-008 — Animate integration contract
- Status: started
- Goal: document exactly where the future 3D engine should mirror, reuse, or stay separate from current Animate architecture
- Current artifact: `docs/07-animate-to-3d-integration.md`

### E-009 — RealityKit style/rendering contract
- Status: started
- Goal: define a RealityKit-native cel-shaded rendering strategy for Amira
- Current artifact: `docs/08-realitykit-style-and-rendering.md`

### E-010 — Camera/style/character schema set
- Status: started
- Goal: define stable preset and registry IDs for camera language, look, and character runtime integration
- Current artifacts:
  - `scaffolding/camera-presets/camera-presets.example.json`
  - `scaffolding/style-profiles/style-profile.example.json`
  - `scaffolding/character-registry/character-registry.example.json`

### E-011 — 3D review/apply preview contract
- Status: started
- Goal: preserve Animate’s preview-first safety model for the 3D engine
- Current artifacts:
  - `docs/10-review-and-apply-preview.md`
  - `scaffolding/review-preview/3d-apply-preview.example.json`

### E-012 — Lighting and atmosphere contract
- Status: started
- Goal: define how light rigs, time-of-day, haze, and atmosphere stay native to the Amira runtime
- Current artifacts:
  - `docs/11-lighting-and-atmosphere-system.md`
  - `scaffolding/light-rigs/light-rig.example.json`
  - `scaffolding/atmosphere-presets/atmosphere-preset.example.json`

### E-013 — Performance and asset intake contract
- Status: started
- Goal: lock down the practical engine constraints before any implementation work begins
- Current artifacts:
  - `docs/12-performance-and-asset-rules.md`
  - `scaffolding/motion-registry/motion-registry.example.json`
  - `scaffolding/viseme-mapping/viseme-mapping.example.json`
