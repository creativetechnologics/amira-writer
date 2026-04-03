# 04 — Proposed 3D Shot Pipeline

Date: 2026-04-01

## Core idea

Do not wire models directly into Amira Writer yet.

Instead, define a **3D shot package** that can later become the boundary between:
- scene/world generation
- asset generation
- motion generation
- facial/mouth animation
- final cel-shaded rendering
- Amira-native runtime playback

---

## Proposed layers

### Layer 1 — World package
Contains:
- environment asset references
- terrain / river / bridge / town set references
- object placements
- scale/origin metadata
- lighting presets
- time-of-day variants

### Layer 2 — Shot package
Contains:
- camera plan
- lens / framing / move metadata
- shot timing
- active world overrides

### Layer 3 — Performance package
Contains:
- body animation tracks
- facial tracks
- mouth/viseme tracks
- gaze / blink / head-turn overlays

### Layer 4 — Render style package
Contains:
- cel-shader profile
- outline profile
- color script / grading preset
- fog / atmosphere profile

---

## Why this separation matters

This lets Amira eventually:
- swap world-generation tools without rewriting the whole stack
- use different asset generators for different asset classes
- keep the **mouth engine** as a separate authority
- preserve reviewability and deterministic overrides

---

## First target architecture

```text
Concept Art / Existing Images
        ↓
Scene Model + Asset Models
        ↓
Optional Cleanup / External Tools
        ↓
3D Shot Package
        ├─ world layer
        ├─ shot layer
        ├─ performance layer
        └─ style layer
        ↓
Preview Runtime (Amira + RealityKit) or Optional External Render
```

---

## Relation to current Animate concepts

### Reused conceptually
- scene plans
- shot-level direction
- object/prop placement
- facial / mouth layering
- review-before-apply mindset

### New for 3D branch
- canonical world/package IDs
- asset references instead of flat image assets
- lighting and atmosphere as first-class shot controls
- separable render-style profiles
- explicit Amira-native runtime state on top of imported USD/assets

---

## Initial decision

If the 3D branch advances, the **shot package** should be designed before any UI work.

That prevents a future 3D tab from becoming a one-off experiment with no durable contract.

