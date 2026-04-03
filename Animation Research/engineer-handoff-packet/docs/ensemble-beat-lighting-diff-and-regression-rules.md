# 98 — Ensemble Beat Lighting Diff And Regression Rules

Date: 2026-03-31

## Purpose
Define how revised ensemble beat-lighting plans should be compared so participant protection, density assumptions, and routing pressure do not regress silently.

## Compared fields
- `sharedLightWorld`
- participant roster and participant count
- beat IDs and beat coverage
- required protected participants per beat
- active protection channels per beat
- continuity notes
- practical channel usage
- computed routing pressure from the ensemble readiness layer

## Block regressions
- shared light world changes
- participant coverage drops for a required protected performer
- a beat loses the continuity note affirming shared-light persistence
- a practical hijacks `ch01_world_key`
- a revised plan drops below the minimum viable participant coverage for the shot
- routing pressure worsens into `ai-video-fallback`

## Warn changes
- participant count decreases while remaining ensemble-valid
- routing pressure rises from `internal` to `hybrid`
- per-participant protection coverage decreases without fully failing
- beat descriptions/focus lists change in a way that suggests new blocking

## Engine-level requirement
The diff logic must stay participant-driven and generic. Named-character fixtures are examples only; production revisions should compare arbitrary participant IDs and explicit protection-channel mappings.
