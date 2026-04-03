# 60 — Script to Lighting Plan Translation

Date: 2026-03-31

## Purpose
Define how plain-language script cues should become deterministic lighting instructions for the runtime.

## Goal
The writer or planner should be able to say things like:
- sunset on the clinic roof
- moonlit street exterior
- fluorescent hospital room
- dust-heavy noon checkpoint

And the system should convert that into a structured `ShotLightingPlan` without asking for manual color grading every time.

## Translation pipeline
1. script parser extracts time-of-day, location type, weather, and practical-light words
2. semantic mapper selects the nearest `LightingProfile`
3. shot planner adds camera/facing context
4. character/background zones inherit the active scene-light model
5. protection flags are applied automatically for face and mouth readability

## Default semantic cues
### Time of day
- dawn -> cool-soft warm-rim mix
- morning -> daylight_soft
- noon -> daylight_hard or dust_storm_flat
- sunset -> sunset_warm
- dusk -> sunset_warm with deeper shadow bias
- night -> moonlight_blue unless interior practicals dominate

### Interior practicals
- fluorescent -> fluorescent_clinic
- tungsten lamp -> tungsten_interior
- fire / candle -> firelight_flicker

### Weather
- dust storm -> lower contrast, flatter shadows, haze increase
- fog / smoke -> stronger depth haze, highlight compression
- clear sky -> cleaner rim and stronger separation

## Protection rules the translator should add automatically
- dialogue or singing shot -> `mouthVisibilityProtection = true`
- close-up or medium close-up -> `faceProtection = true`
- important costume/prop story beat -> palette clamp stays tighter

## Output principle
The translator should emit editable deterministic JSON, not final pixel operations.
