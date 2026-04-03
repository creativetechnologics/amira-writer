# 10 — Review and Apply Preview Model

Date: 2026-04-01

## Goal

Preserve one of Animate’s strongest existing ideas:

> the LLM does not directly mutate the scene without a structured preview of what will change.

For the Amira-native 3D engine, that means every 3D command plan should compile into a **reviewable apply preview** before it touches runtime state.

---

## Why this matters

The current Animate architecture already has:
- review
- apply preview
- shot-slice preview
- warning aggregation
- effect counts

That same safety model should become first-class in 3D.

---

## Proposed 3D effect scopes

### World-level
- `worldState`
- `environmentState`

Examples:
- active world changed
- time-of-day preset changed
- atmosphere profile changed

### Asset-level
- `assetPlacement`
- `assetState`

Examples:
- bridge placed
- lantern visibility changed
- prop material variant switched

### Camera-level
- `cameraState`
- `cameraTrack`

Examples:
- shot preset applied
- dolly path updated
- focus target changed

### Character-level
- `characterState`
- `motionTrack`
- `faceTrack`
- `mouthTrack`

Examples:
- character spawned
- motion clip changed
- expression override added
- viseme track applied

### Style-level
- `styleState`
- `lightRig`

Examples:
- toon style profile changed
- outline width changed
- sunrise rig replaced with lantern-night rig

---

## Suggested preview structure

```text
3D command plan
        ↓
validation
        ↓
resolved 3D apply preview
        ↓
review UI
        ↓
apply
```

The review output should include:
- warnings
- effect count
- actionable effect count
- no-change effect count
- shot contexts
- stable target IDs

---

## Recommended UI behavior

For each effect:
- show scope
- show target
- show current value
- show proposed value
- show change kind
- show shot context if relevant

This should mirror current Animate behavior as closely as possible.

---

## Engine rule

No LLM-authored 3D plan should bypass preview unless the user explicitly enables an apply-without-preview path later.

Preview-first is a core Amira safety feature.

