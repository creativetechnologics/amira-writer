# 90 — Ensemble Beat Lighting Readiness

Date: 2026-03-31

## Purpose
Score whether a multi-character beat-lighting plan is strong enough for internal, hybrid, or fallback routing when more than two performers share the same shot.

## Engine-level requirement
This contract must remain cast-agnostic. Test fixtures may use named characters, but production packets should always describe participants through explicit metadata:
- `participantId`
- `role`
- `packageReadiness`
- `protectChannel`

## Required inputs
- shared beat-lighting plan data
- `sharedLightWorld`
- `locationId`
- `lightingProfile`
- `revisionSensitivity`
- participant list with readiness + protection-channel assignments
- per-beat:
  - `focusParticipants`
  - `visibleParticipants`
  - `requiredProtectedParticipants`
  - `activeProtectionChannels`
  - `activePracticalChannels`
  - `continuityNotes`

## Scoring dimensions
- **continuity** — shared-light continuity preserved beat to beat
- **focus protection** — focused performers receive their required protection channels
- **ensemble protection** — all explicitly required protected participants are covered
- **practical discipline** — practicals stay subordinate to the world key
- **package support** — average and floor readiness across participating performers
- **ensemble density** — higher participant counts reduce internal confidence unless coverage remains excellent

## Result fields
- `participantCount`
- `continuityScore`
- `focusProtectionScore`
- `ensembleProtectionScore`
- `practicalScore`
- `packageScore`
- `packageFloor`
- `ensembleDensityScore`
- `weightedScore`
- `readinessTier`
- `recommendedRouting`
- `perParticipantCoverage`
- `blockingIssues`
- `warnings`

## Blocking rules
- missing `sharedLightWorld`
- any required protected participant missing their protection channel on a beat
- any practical that hijacks `ch01_world_key`
- any participant below `blocking-ready`

## Routing rule
- **internal** only when coverage is excellent, package floor is solid, and cast density is still manageable
- **hybrid** for most medium/large ensemble scenes even when readiness is high
- **ai-video-fallback** when continuity/protection breaks or participant readiness floor is too low
