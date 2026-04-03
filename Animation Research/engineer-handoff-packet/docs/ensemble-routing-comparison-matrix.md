# 92 — Ensemble Routing Comparison Matrix

Date: 2026-03-31

## Purpose
Compare `internal`, `hybrid`, and `ai-video-fallback` for larger-cast scenes under the same shared lighting worlds so routing decisions remain engine-level and location-aware.

## Core rule
Routing changes must not imply a different lighting world.
The same `locationId`, `lightingProfile`, and shared-light contract remain active; only execution strategy changes.

## Engine-level requirement
Comparisons should be participant-driven, not hero-name-driven. Production fixtures should always describe:
- `participantCount`
- `leadCount`
- `supportCount`
- `lightingProfile`
- `sharedLightWorld`
- `routeOptions`
- `baselineRecommendation`

## Comparison fields
Each ensemble routing comparison entry should include:
- `comparisonId`
- `locationId`
- `participantCount`
- `leadCount`
- `supportCount`
- `lightingProfile`
- `sharedLightWorld`
- `baselineRecommendation`
- `decisionReasons`
- `routeOptions`

## Route-option requirements
For each location, compare:
- `internal`
- `hybrid`
- `ai-video-fallback`

Each route option should clarify:
- what remains inside the internal engine
- what crosses an assist/fallback boundary
- how the shared light world remains unified
- how ensemble density affects risk

## Baseline guidance
- controlled 4-person daylight/interior ensembles may still justify `internal`
- most 4–5 person scenes should lean `hybrid`
- fragile night-practical ensembles should default to `hybrid`
- `ai-video-fallback` should be baseline only when density and motion exceed continuity-friendly limits
