# 80 — Duet Routing Comparison Matrix

Date: 2026-03-31

## Purpose
Compare `internal`, `hybrid`, and `ai-video-fallback` under the same duet lighting worlds so engineering can see when routing changes are justified without changing the location light itself.

## Core rule
Routing changes should not imply a different lighting world.
The same `locationId`, `lightingProfile`, and channel contract remain active; only the execution strategy changes.

## Comparison fields
Each routing comparison entry should include:
- `comparisonId`
- `locationId`
- `lightingProfile`
- `sharedLightWorld`
- `routeOptions`
- `baselineRecommendation`
- `decisionReasons`

## Route-option requirements
For each location, compare:
- `internal`
- `hybrid`
- `ai-video-fallback`

Each route option should spell out:
- what stays inside the internal engine
- what moves to assist/fallback systems
- why the same light world is still valid
- what risks increase or decrease

## First-use locations
- district clinic exterior
- rooftop sunset
- village street night
- clinic interior fluorescent
- family courtyard
