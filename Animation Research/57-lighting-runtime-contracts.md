# 57 — Lighting Runtime Contracts

Date: 2026-03-31

## Purpose
Define the research-side contracts needed for a future lighting engine.

## New contract objects

### LightingProfile
Defines reusable lighting behavior.

Fields should include:
- `id`
- `category` (`day`, `sunset`, `night`, `interior`, `special`)
- `globalTint`
- `shadowTint`
- `highlightTint`
- `contrastBias`
- `saturationBias`
- `rimLight`
- `atmosphere`
- `practicalSources`

### LightingResponseProfile
Defines how a material or asset family reacts.

Fields should include:
- `id`
- `materialFamily`
- `tintSensitivity`
- `shadowStrength`
- `highlightClamp`
- `lineProtection`
- `skinToneProtection`
- `allowEmissiveBoost`

### ShotLightingPlan
Defines the specific lighting instructions for one shot.

Fields should include:
- `profileId`
- `timeOfDay`
- `weather`
- `keyDirection`
- `cameraFacingBias`
- `characterZones`
- `backgroundZones`
- `practicalOverrides`
- `faceProtection`
- `mouthVisibilityProtection`
- `paletteClamp`

### LightingReviewResult
Structured output from the QA layer.

Suggested fields:
- `readability`
- `skinTonePreserved`
- `backgroundMatch`
- `lineIntegrity`
- `requiresRegeneration`
- `suggestedCorrections`

## Runtime stage order
1. resolve active `LightingProfile`
2. merge `ShotLightingPlan` overrides
3. look up per-material `LightingResponseProfile`
4. compute character/background grade passes
5. apply readability protection rules
6. emit a reviewable lighting result record

## Placement in future adapters
Add a future `LightingRuntimeAdapter` beside:
- `MotionPlanAdapter`
- `MouthOverlayAdapter`
- `AssetReviewAdapter`

Responsibilities:
- normalize shot lighting plans
- resolve profile ids
- apply default protection rules
- expose diagnostics for QA

## Principle
Lighting instructions should remain deterministic JSON-like contracts rather than ad hoc prompt text.
