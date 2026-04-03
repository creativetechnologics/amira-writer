# 23 — First Implementation Sprint Plan

Date: 2026-03-31

## Goal
Convert the research sandbox into the smallest real pilot inside Amira Writer later, without destabilizing the app.

## Sprint 1 scope
- add a vNext manifest loader behind a feature flag
- add a research-only motion-plan parser into a test harness or debug-only path
- add a mouth-profile loader and speech-only overlay playback for one character
- add a review-record store for generated assets

## Out of scope
- complex multi-character blocking
- full locomotion library
- AI video routing
- automatic correction orchestration in production
- production UI for all package concepts

## Deliverables
1. `PackageManifestAdapter`
2. `MotionPlanAdapter`
3. `MouthOverlayAdapter`
4. test fixture package and motion plan
5. one sample scene playback path

## Suggested order
### Week 1
- manifest adapter
- package fixture loading
- validation utilities

### Week 2
- motion plan parser
- character-state binding
- primitive playback hooks

### Week 3
- mouth profile loader
- speech-only mouth event playback
- anchor placement checks

### Week 4
- QA/review record storage
- first end-to-end pilot validation
- write implementation handoff notes

## Exit criteria
The sprint succeeds if one approved character package can drive one internal dialogue shot with:
- stable identity
- correct costume
- basic acting pose
- acceptable mouth movement
- reproducible plan playback
