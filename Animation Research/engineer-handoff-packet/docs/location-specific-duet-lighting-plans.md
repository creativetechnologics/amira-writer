# 75 — Location-Specific Duet Lighting Plans

Date: 2026-03-31

## Purpose
Provide one dedicated lighting-plan JSON per top duet location so engineering has deterministic, location-scoped fixtures instead of only high-level packet summaries.

## Required fields per JSON
- `locationId`
- `shotId`
- `lightingProfile`
- `sharedLightWorld`
- `lukeReadPriorities`
- `amiraReadPriorities`
- `zoneMetadata`
- `practicalMetadata`
- `fixtureMappings`

## Shared-light principle
Each file should describe one unified light world for both characters.
Local protection is allowed, but only in ways that do not contradict the common scene light.

## Character read blocks
Luke and Amira each get their own read-priority block containing:
- primary read goals
- risks
- protection flags
- fixture mappings back to package and pilot assets

## Why per-location files matter
The duet packet tells us what the shot is.
The location-specific lighting-plan file tells us exactly how that shot should be lit and protected.
