# 86 — Beat Lighting Continuity And Regression Rules

Date: 2026-03-31

## Purpose
Define how beat-level lighting plans should preserve continuity and how revised beat plans should be compared.

## Single-plan continuity rules
A valid beat-lighting plan should:
- keep one `sharedLightWorld` for the whole shot
- keep continuity notes on every beat confirming shared-world persistence
- include protection channels whenever the beat is dialogue or singing focused
- avoid practical-channel assignments that hijack `ch01_world_key`

## Revision diff rules
When a beat-lighting plan is revised, compare:
- top-level `sharedLightWorld`
- beat count and beat IDs
- protection-channel coverage
- mouth overlay bias changes
- practical-channel usage changes

## Block regressions
- shared light world changes between baseline and revised plan
- any beat loses all protection channels
- any beat loses the continuity note affirming shared-world persistence
- a practical takes over `ch01_world_key` directly

## Warn changes
- mouth overlay bias changes
- a beat changes practical emphasis substantially
- beat descriptions change in a way that suggests new blocking
