# 59 — Lighting Engine Handoff

Date: 2026-03-31

## Purpose
Summarize what engineers should build first for lighting when the sandbox work moves into implementation.

## First pilot lighting target
A narrow pilot is enough:
- one hero character
- one costume
- one background
- three reusable lighting profiles:
  - daylight_soft
  - sunset_warm
  - moonlight_blue
- face/mouth readability protection enabled

## First engineering milestones
1. Load `LightingProfile` JSON
2. Load `LightingResponseProfile` JSON
3. Load `ShotLightingPlan` JSON
4. Apply deterministic grade passes in a research-only runtime harness
5. Emit `LightingReviewResult`
6. Validate against the pilot acceptance matrix

## Asset metadata required for pilot
For each relevant asset family, store:
- material family
- line preservation weight
- skin tone protection flag
- tint sensitivity
- highlight clamp

## Minimal fixtures required
- one lighting profile library fixture
- one shot lighting plan fixture
- one material-response fixture
- one lighting review fixture

## Pilot success criteria
- character and background clearly match the same time of day
- face remains readable
- mouth remains readable in dialogue/singing
- line art remains stable
- no asset regeneration required for basic day/sunset/night shifts

## Non-goals for pilot
- fully dynamic cast-shadow geometry
- complex volumetric simulation
- physically based rendering
- arbitrary 3D light reconstruction

## Recommendation
Treat lighting as a dedicated runtime adapter from the start, not as a late-stage color-correction hack.
