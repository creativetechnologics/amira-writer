# 91 — Ensemble Beat Lighting Routing

Date: 2026-03-31

## Purpose
Map ensemble beat-lighting readiness into execution routing while keeping the lighting world unified.

## Bridge rules
- `fallback-only` readiness tier always maps to `ai-video-fallback`
- `hybrid-ready` maps to `hybrid`
- `internal-ready` can still downgrade to `hybrid` when:
  - participant count is high
  - practical density is high
  - the location is inherently fragile (night practicals, crowd occlusion, moving pools of light)

## Ensemble-specific override logic
- 5+ active participants should almost never default to `internal`
- `village-street-night` remains hybrid-biased for ensemble scenes
- interior fluorescent dialogue ensembles may still qualify for `internal` if protection and continuity remain stable

## Engine-level requirement
Do not encode routing around named heroes. The bridge should work from participant metadata, location metadata, and beat-lighting scores only.
