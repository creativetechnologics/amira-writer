# 12 — Performance and Asset Rules

Date: 2026-04-01

## Goal

Capture the practical constraints that should shape the Amira-native 3D engine before any implementation begins.

---

## Apple-backed constraints

### 1. ECS work has CPU cost
Apple’s performance guidance emphasizes:
- reducing CPU utilization
- careful custom-component design
- avoiding unnecessary system work
- flattening and simplifying where appropriate

Implication:
- Amira should prefer reusable world chunks and stable scene structures
- not enormous numbers of tiny independently-updated entities

Sources:
- https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app
- https://developer.apple.com/documentation/realitykit/reducing-cpu-utilization-in-your-realitykit-app

### 2. Imported material complexity should stay simple
Apple’s USD validation docs note that RealityKit import paths support only a **single packed texture per material**.

Implication:
- imported materials should be treated as simplified asset carriers
- Amira’s stylized renderer should own the final look

Source:
- https://developer.apple.com/documentation/usd/validating-usd-files

### 3. Imported lights should not be trusted
Again from Apple’s USD validation docs:
- imported USD lights are not authoritative runtime lights in RealityKit

Implication:
- geometry import and lighting control must be separate concerns

Source:
- https://developer.apple.com/documentation/usd/validating-usd-files

---

## Engine rules

### Rule 1 — Geometry first, materials second
Evaluate generated/imported assets primarily for:
- silhouette
- proportions
- rig usefulness
- topology sanity

Material look is secondary because Amira will restyle assets.

### Rule 2 — Stable IDs everywhere
Everything should have stable IDs:
- world IDs
- asset IDs
- character IDs
- motion IDs
- style IDs
- light rig IDs
- atmosphere IDs

This is what makes LLM command replay and preview safe.

### Rule 3 — Prefer world chunks over giant monoliths
Use reusable world slices such as:
- valley
- river
- bridge
- town core
- streets
- overlooks

This is better for performance and directing than one giant mesh world.

### Rule 4 — Keep style profiles small and shared
Avoid per-shot custom materials whenever possible.

Favor:
- a few shared style presets
- a few light rigs
- a few atmosphere presets

### Rule 5 — Every character needs a clean runtime contract
Each character should define:
- body asset
- face rig
- mouth profile
- supported motion sets
- fallback clip families

---

## Intake rules

### Asset intake
Every asset should record:
- source model/tool
- cleanup status
- style readiness
- runtime readiness
- collision readiness

Suggested classes:
- `prototype_only`
- `generated_then_cleaned`
- `manual_blockout`
- `production_ready`

### Motion intake
Every motion clip should record:
- source tool/model
- skeleton compatibility
- loop suitability
- root-motion behavior
- emotional/action tags
- dialogue suitability

---

## First performance target

Do not optimize for a giant world first.

Optimize for:
- one world slice
- one or two characters
- one camera path
- one stylized render profile
- one deterministic review/apply loop

That is enough to prove the engine.

