# 58 — Background Lighting and Scene Grade

Date: 2026-03-31

## Purpose
Extend the lighting engine design beyond characters so the entire shot feels unified.

## Scene-grade model
Background lighting should operate on depth-aware grade zones instead of a single blanket tint.

Suggested zones:
- sky
- far background
- mid background
- near background
- ground plane
- interior practical-light pools
- dust/haze overlays

## Background operations
- depth tint by zone
- shadow softening/hardening by time of day
- atmosphere color shift
- haze density adjustment
- local practical light pools
- emissive windows / lamps / fire sources
- palette clamp so the environment stays within the visual language of the film

## Character/background unification
Every shot should share a single lighting plan that contains both:
- character lighting instructions
- background zone grading instructions

That avoids the common failure where the character looks sunset-lit but the background remains neutral daylight.

## Preferred strategy
Use one source of truth for the shot, then derive:
- character relight passes
- background relight passes
- atmosphere overlays
- practical highlights

## Fallback rule
If a background cannot be convincingly corrected with the planned grade because its geometry/light assumption is fundamentally incompatible, the shot router should flag it for:
- edit/repaint pass, or
- regenerate background only

## QA checks
The review layer should verify:
- shared light direction plausibility
- character/background palette harmony
- face readability despite strong scene mood
- preserved depth separation
- no unreadable shadow crush in important story zones
