# 65 — Lighting Profile Library

Date: 2026-03-31

## Purpose
Define the starter library of reusable lighting profiles that should exist before live integration begins.

## Recommended minimum library

### Exterior daylight
- `daylight_soft`
- `daylight_hard`
- `dust_storm_flat`

### Exterior transition times
- `dawn_cool`
- `sunset_warm`
- `dusk_desaturated`

### Night
- `moonlight_blue`
- `night_practical_mix`

### Interior practicals
- `fluorescent_clinic`
- `tungsten_interior`
- `firelight_flicker`

## Selection rule
The script translator should choose a base profile from this library, then apply shot-level overrides rather than inventing brand-new lighting behavior for every shot.

## Library design rules
- every profile should be named, reusable, and reviewable
- every profile should support character + background grading together
- every profile should declare whether face protection is usually required
- every profile should be tested against at least one hero character and one key location

## Pilot recommendation
The first implementation pilot should only require:
- `daylight_soft`
- `sunset_warm`
- `moonlight_blue`
- `fluorescent_clinic`
