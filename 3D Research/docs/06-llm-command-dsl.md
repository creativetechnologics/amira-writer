# 06 — LLM Command DSL for the 3D Engine

Date: 2026-04-01

## Goal

Define a command language that lets the LLM act like:
- director
- cinematographer
- layout supervisor
- lighting supervisor
- animation planner

without giving it direct low-level rendering responsibility.

---

## Design rule

Commands should be:
- **explicit**
- **reviewable**
- **deterministic**
- **diffable**
- **replayable**

They should not be free-form prose after compilation.

---

## Proposed command families

### 1. World commands
- `set_world_variant`
- `set_time_of_day`
- `set_weather`
- `set_atmosphere`
- `toggle_world_element`

### 2. Asset/layout commands
- `place_asset`
- `move_asset`
- `rotate_asset`
- `scale_asset`
- `set_asset_state`

### 3. Character commands
- `spawn_character`
- `move_character`
- `play_motion_clip`
- `set_expression`
- `look_at`
- `set_visibility`

### 4. Mouth/facial commands
- `play_dialogue_track`
- `apply_viseme_track`
- `set_mouth_mode`
- `set_facial_intensity`

### 5. Camera commands
- `set_camera_preset`
- `cut_camera`
- `move_camera`
- `orbit_camera`
- `track_target`
- `set_focus_target`

### 6. Style commands
- `set_style_profile`
- `set_outline_profile`
- `set_grade_profile`
- `set_light_rig`

---

## Why this fits Amira

The current Animate system already uses structured plan data for:
- camera
- object placement
- motion
- dialogue
- mouth tracks

So the safest evolution is:
- keep the same philosophy
- widen the vocabulary for 3D scene/runtime commands

---

## Compiler model

```text
LLM prompt / direction
        ↓
3D command plan JSON
        ↓
validator
        ↓
shot resolver
        ↓
runtime mutations
        ↓
preview / review / apply
```

---

## Validation rules

The command compiler should reject or warn on:
- unknown asset IDs
- unknown world IDs
- conflicting camera commands
- missing motion clips
- mouth track applied without a valid dialogue target
- lighting/style presets that do not exist

---

## Important Amira-specific simplification

Because this engine is only for Amira, the DSL can assume:
- a fixed set of worlds
- a fixed set of characters
- a recurring visual language
- a small number of lighting/story presets

That means we do **not** need a giant universal command surface.

We need a **small, high-confidence command surface**.

---

## Recommended first schema slices

1. **World + style**
2. **Camera**
3. **Objects/assets**
4. **Characters**
5. **Dialogue + mouth**

This ordering matches what will let us see useful preview results soonest.

