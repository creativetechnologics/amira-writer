# 08 — RealityKit Style and Rendering Strategy

Date: 2026-04-01

## Goal

Define how Amira can achieve a stylized anime/cel-shaded look in a native RealityKit-based engine.

---

## Executive summary

Apple’s official sources are strong enough to support a credible stylized-rendering path:

- RealityKit 4 supports **custom materials**, **MaterialX shaders**, and **custom render targets**
- Apple documents **Metal-based custom material shaders**
- Apple video/docs also point to **custom post effects**

That means Amira can plausibly build a stylized look from a combination of:

1. **Custom materials** for toon bands and material stylization
2. **Geometry modifier / duplicate-mesh techniques** for outline options
3. **Post-processing** for additional edge treatment or grading
4. **Native lighting/time-of-day systems** in Amira

### Important inference
Apple does **not** appear to expose a built-in “anime toon outline” mode in RealityKit.  
So the outline/look pipeline should be treated as an **Amira-authored rendering layer**, built from lower-level rendering hooks.

---

## Source-backed capabilities

### 1. Custom materials
Apple’s custom materials documentation says RealityKit supports:
- Metal **surface shaders**
- Metal **geometry modifiers**
- selectable lighting models:
  - `.lit`
  - `.clearcoat`
  - `.unlit`

This is enough to justify:
- quantized toon-band lighting
- stylized albedo treatment
- procedural rim/fresnel stylization
- geometry-based outline tricks

Source:
- https://developer.apple.com/documentation/realitykit/modifying-realitykit-rendering-using-custom-materials

### 2. MaterialX / shader graph support
Apple’s RealityKit overview says:
- shaders built with **MaterialX** can be used with `RealityView` on all four platforms

Apple’s USD validation docs also mention MaterialX support on recent macOS/iOS/visionOS versions.

This matters because it gives Amira two viable shader-authoring paths:
- code-driven Metal custom materials
- node/material-graph driven MaterialX

Sources:
- https://developer.apple.com/augmented-reality/realitykit/
- https://developer.apple.com/documentation/usd/validating-usd-files

### 3. Custom render targets / post effects
Apple’s RealityKit overview says RealityKit gives more control over the pipeline with:
- **custom render targets**
- **custom materials**

Apple’s WWDC21 advanced rendering session explicitly mentions:
- **custom post effects**

This is a key clue for Amira because it makes a post-process edge treatment or stylized composite layer realistic.

Sources:
- https://developer.apple.com/augmented-reality/realitykit/
- https://developer.apple.com/videos/play/wwdc2021/10075/

---

## Recommended Amira rendering stack

### Layer 1 — Base toon material
Use:
- `CustomMaterial`
- `.lit` lighting model

Purpose:
- respond to native Amira light rigs
- quantize diffuse lighting into 2–4 bands
- preserve consistent color palettes

This should be the default for:
- environment assets
- props
- most character surfaces

### Layer 2 — Character face/mouth material control
Use:
- targeted custom materials or shader-graph materials
- runtime parameters for:
  - shadow threshold
  - rim amount
  - mouth/face emphasis

Purpose:
- keep faces readable
- avoid overly noisy stylization on expressive regions

### Layer 3 — Outline system
Recommended order of experimentation:

1. **Geometry-based outline**
   - duplicate shell / inverted hull style technique
   - likely easiest to control deterministically
2. **Post-process edge enhancement**
   - if custom render target path proves practical
3. **Hybrid**
   - geometry outlines on characters/hero props
   - post edge treatment on environment

#### Why geometry-first
Apple’s custom material docs explicitly support geometry modifiers.  
That makes geometry-driven outline experiments easier to justify from official capability alone.

Important caveat:
- geometry modifier movement only affects rendering, not physics/collision
- if vertices move outside bounds, `boundsMargin` must be increased

Source:
- https://developer.apple.com/documentation/realitykit/modifying-realitykit-rendering-using-custom-materials

### Layer 4 — Native atmosphere/time-of-day
Because Apple’s USD validation docs say RealityKit does not use imported USD lights as authoritative renderer lights:
- sunrise/day/dusk/night should be native presets
- haze/fog should be native style controls
- grade and color script should be native

This is a strength, not a weakness:
- it makes the Amira look consistent
- it keeps art direction centralized

Source:
- https://developer.apple.com/documentation/usd/validating-usd-files

### Layer 5 — Post-grade and composite
Use a lightweight post/composite layer for:
- color grade
- highlight compression
- selective bloom if ever needed
- edge enhancement if adopted

This should be optional and conservative.

---

## Recommended style presets

Amira should not expose “infinite shader knobs” at first.

Instead, define a small style preset set:

- `amira_toon_v001`
- `amira_night_lantern_v001`
- `amira_blue_hour_v001`
- `amira_closeup_face_v001`

Each preset should define:
- band count
- shadow threshold
- rim intensity
- saturation bias
- outline width bias
- fog/haze profile
- highlight rolloff

---

## Risks

### 1. Built-in style support is not “anime turnkey”
Inference from Apple sources:
- RealityKit is flexible enough
- but there is no source-backed indication of a built-in anime renderer

### 2. Outline strategy may need iteration
Most likely unknown:
- which is cleaner on macOS for Amira’s look:
  - geometry outlines
  - postprocess outlines
  - hybrid

### 3. Performance pressure
Apple’s RealityKit performance docs emphasize reducing mesh/material/texture complexity.

Apple’s USD validation docs also note that RealityKit import paths support only **one packed texture per material**, which is another reason to keep Amira’s material strategy tight and stylized rather than PBR-heavy.

That means Amira should:
- keep materials shared
- use style presets
- avoid uncontrolled material proliferation
- prefer reusable world chunks

Source:
- https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app
- https://developer.apple.com/documentation/realitykit/reducing-cpu-utilization-in-your-realitykit-app
- https://developer.apple.com/documentation/usd/validating-usd-files

### 4. Imported lighting is not authoritative
Apple’s USD validation docs explicitly say RealityKit does **not** use lights embedded in USD files.

Implication:
- geometry can come from USD
- rigs can come from USD
- animation can come from USD
- but final light rigs, time-of-day, and atmosphere should stay native to Amira

Source:
- https://developer.apple.com/documentation/usd/validating-usd-files

---

## Recommendation

Build the first stylized renderer around:

1. **CustomMaterial toon bands**
2. **native Amira light rigs**
3. **native time-of-day/atmosphere presets**
4. **geometry-first outline experiments**
5. **optional post edge/composite later**

This is the most defensible RealityKit-first rendering path from the current official Apple capabilities.
