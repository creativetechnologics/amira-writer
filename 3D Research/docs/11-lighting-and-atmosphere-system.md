# 11 — Lighting and Atmosphere System

Date: 2026-04-01

## Goal

Define how lighting, time-of-day, haze, fog, and mood should work in the Amira-native 3D engine.

---

## Core rule

Lighting must be **native Amira runtime state**.

Why:
- Apple’s USD validation docs explicitly say RealityKit does **not** use lights embedded in a USD file

That means:
- imported USD assets can carry geometry, skeletons, variants, and animations
- but shot lighting and atmospheric mood must be authored by Amira itself

Source:
- https://developer.apple.com/documentation/usd/validating-usd-files

---

## Recommended lighting architecture

### 1. World light rig
Persistent environment-level lighting for each world.

Examples:
- `sunrise_soft_directional`
- `day_clear_open`
- `late_afternoon_gold`
- `night_lantern_core`

### 2. Shot overrides
Shot-specific cinematic modifications on top of the world rig.

Examples:
- key light lift on a closeup
- lantern practical boost
- bridge silhouette accent
- square fill-light softening

### 3. Atmosphere preset
Distance and mood systems.

Examples:
- `light_morning_haze`
- `river_mist_low`
- `blue_hour_depth`
- `night_lamp_halo_low`

### 4. Style response
The style layer decides how lighting becomes cel shading.

Examples:
- shadow threshold
- highlight clamp
- rim intensity
- saturation response

---

## Likely technical implementation

### Native light components
Use RealityKit-native light and shadow systems for the actual light rig.

Relevant Apple references:
- `SpotLightComponent`
- directional light support
- renderer lighting APIs
- dynamic shadow component

Sources:
- https://developer.apple.com/documentation/RealityKit/SpotLightComponent
- https://developer.apple.com/documentation/realitykit/hasdirectionallight
- https://developer.apple.com/documentation/realitykit/realityrenderer/lighting
- https://developer.apple.com/documentation/realitykit/dynamiclightshadowcomponent

### Atmosphere / fog
Treat atmosphere as a custom native effect layer.

Most realistic first assumption:
- depth-based fog/haze in a post-processing path

Apple references that support this direction:
- ARKit depth-fog example
- RealityKit advanced rendering session
- RealityKit postprocessing docs

Sources:
- https://developer.apple.com/documentation/arkit/creating-a-fog-effect-using-scene-depth
- https://developer.apple.com/videos/play/wwdc2021/10075/
- https://developer.apple.com/documentation/realitykit/postprocessing-effects?changes=latest_minor

---

## Preset-first rule

Do **not** build a giant physically-based lighting sandbox first.

Build a small deterministic preset system:
- world light rigs
- time-of-day presets
- atmosphere presets
- shot overrides

This is enough for Amira’s recurring environments and gives the LLM a safer command surface.

---

## Ownership model

### WorldGraph owns
- default world light rig
- default atmosphere profile
- default time-of-day preset

### ShotGraph owns
- shot-level overrides
- emphasis lights
- camera-linked timing

### StyleGraph owns
- how light becomes toon bands
- rim/fill response
- outline contrast response

