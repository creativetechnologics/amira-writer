# 26 — Shot Routing Decision Matrix

Date: 2026-03-31

## Purpose
Decide whether a shot should be handled by the internal animation engine, a hybrid path, or AI-video fallback.

## Routing modes
- internal
- hybrid
- ai-video-fallback

## Internal route when
- one or two characters
- reusable package coverage exists
- motion is sparse-keyframe friendly
- camera is limited or predictable
- continuity and revision control matter most

Examples:
- dialogue shot
- medium close-up singing shot
- walk-and-talk with limited staging complexity
- reaction shots

## Hybrid route when
- the base acting can be done internally
- but one layer is hard or expensive
- an AI edit/fill could solve the gap better than full AI video

Examples:
- internal character acting + AI-generated environmental effect pass
- internal blocking + AI-assisted cloth or complex overlay correction
- internal staging + AI-generated start/end beauty frames for difficult transitions

## AI-video fallback when
- camera motion is highly complex
- dense crowd interaction is required
- the shot would demand too many bespoke assets
- atmospheric complexity dominates character precision

Examples:
- sweeping battlefield or crowd movement
- difficult chase/action inserts
- complex environmental destruction or heavy FX moments

## Decision inputs
- character count
- package readiness score
- costume coverage
- mouth coverage
- prop complexity
- camera complexity
- environmental FX complexity
- revision sensitivity

## Suggested score model
### Prefer internal
- package readiness high
- camera complexity low/medium
- acting complexity low/medium
- revision sensitivity high

### Prefer hybrid
- package readiness medium/high
- one specific complexity axis spikes
- revision sensitivity still matters

### Prefer AI-video fallback
- package readiness low for the needed shot
- camera/environment/action complexity high
- exact retake control is less important than achieving the spectacle efficiently

## Production rule
Default to internal when feasible.
Use hybrid second.
Use full AI-video fallback only when the shot clearly exceeds the internal package/runtime envelope.
