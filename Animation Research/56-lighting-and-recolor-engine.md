# 56 — Lighting and Recolor Engine

Date: 2026-03-31

## Purpose
Define a reusable lighting subsystem that can re-light already-generated character and background assets without regenerating them in most cases.

## Core principle
Lighting should be treated as a runtime interpretation layer, not as a baked property of the source art.

That means the system should:
- preserve line art and form readability
- recolor base assets according to scene conditions
- add controlled highlights, rims, bounce, and shadow bias
- support both characters and backgrounds with the same shot-level lighting plan
- prefer reversible grading and overlays before choosing regeneration

## Why this engine is necessary
The script may say:
- sunset exterior
- blue moonlit night
- fluorescent clinic interior
- dust storm afternoon
- firelit close-up

If every one of those requires new art generation, costs and continuity risks explode.

So the lighting engine should let the runtime transform approved assets into the correct shot mood while preserving:
- costume identity
- skin tone identity
- material readability
- anime-style color discipline

## Recommended subsystem split

### 1. Lighting profile library
Reusable named light conditions such as:
- daylight_hard
- daylight_soft
- sunset_warm
- moonlight_blue
- fluorescent_clinic
- tungsten_interior
- dust_storm_flat
- firelight_flicker

Each profile should define:
- key hue / tint
- fill hue / tint
- shadow bias
- highlight intensity
- rim-light settings
- background atmosphere tint
- contrast curve hints
- saturation compression rules

### 2. Asset response metadata
Each asset family should declare how it responds to light.

Examples:
- skin
- hair
- sclera
- iris
- cotton fabric
- canvas strap
- metal buckle
- leather boot
- concrete wall
- sky plane
- sand / dust plane

The response metadata should include:
- tint sensitivity
- shadow tolerance
- highlight clamp
- line-preservation weight
- warmth/coolness shift range
- emissive allowance

### 3. Shot lighting plan
The LLM/script planner should not emit raw RGB commands.
It should emit a structured shot lighting plan that references:
- a profile id
- time of day
- weather/atmosphere
- practical light sources
- character depth zones
- background depth zones
- optional special accents (fire, flashlight, window shafts)

### 4. Runtime lighting compositor
This runtime stage applies:
- global grade
- material-aware recolor
- shadow ramps
- local key/fill adjustments
- optional rim overlays
- atmosphere/depth fade
- practical light masks

### 5. Lighting QA layer
The review loop should check:
- readability loss
- skin tone drift beyond tolerance
- costume palette corruption
- line-art washout
- background/character mismatch
- whether relight failed badly enough to require regeneration

## Recommended lighting stack order
1. Base asset render
2. Global scene grade
3. Material-aware recolor pass
4. Shadow bias pass
5. Rim / key accent pass
6. Practical-light overlays
7. Atmosphere/depth haze
8. Final palette clamp for style consistency

## Character-specific requirements
For characters, the engine should preserve:
- face readability
- eye clarity
- mouth visibility during dialogue/singing
- costume distinction
- silhouette against the background

The engine should also allow shot rules like:
- protect face exposure
- protect lip-sync readability
- preserve medic insignia readability only if narratively needed

## Background-specific requirements
Backgrounds need:
- zone-based depth grading
- sky/ground separation
- local practical light pools
- haze control
- compatibility with the character grade so they feel lit by the same world

## When relight is enough vs regenerate
Relight only when the failure is mainly:
- mood mismatch
- time-of-day mismatch
- palette mismatch
- weak rim / shadow / fill balance
- insufficient atmosphere

Prefer regeneration when:
- the background geometry assumes the wrong light direction
- cast shadows are fundamentally incorrect
- costume design/details disappear under attempted correction
- the original asset has no recoverable separation for key visual planes

## Integration takeaway
The future system should be:
- body engine
- mouth engine
- lighting engine
- QA/review/promotion layer
- shot router

Lighting becomes a first-class runtime system, not an afterthought.
