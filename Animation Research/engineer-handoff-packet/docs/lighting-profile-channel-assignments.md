# 76 — Location Lighting Profile Channel Assignments

Date: 2026-03-31

## Purpose
Turn the profile-family map into deterministic, location-ready channel assignments that future runtime code can consume without inventing a new lighting graph for every shot.

## Canonical channel lanes
- `ch01_world_key`
- `ch02_world_fill`
- `ch03_world_rim`
- `ch04_background_separation`
- `ch05_practical_accent`
- `ch06_atmosphere_grade`
- `ch07_luke_protect`
- `ch08_amira_protect`

## District clinic exterior
Primary family: `daylight_soft`
- `ch01_world_key`: sky-side key from open street
- `ch02_world_fill`: clinic facade bounce
- `ch03_world_rim`: opposite-side soft shoulder edge
- `ch04_background_separation`: doorway and signage value split
- `ch05_practical_accent`: doorway bounce only
- `ch06_atmosphere_grade`: light dust haze
- `ch07_luke_protect`: pocket / satchel / jaw split
- `ch08_amira_protect`: face contour / scarf edge / brow readability

Alternates:
- `sunset_warm` swaps `ch01_world_key` to low warm horizon and raises `ch03_world_rim`
- `moonlight_blue` lowers `ch02_world_fill` and lets `ch05_practical_accent` carry doorway spill

## Rooftop sunset
Primary family: `sunset_warm`
- `ch01_world_key`: low horizon sun key
- `ch02_world_fill`: weak sky counter-fill
- `ch03_world_rim`: parapet / head edge rim
- `ch04_background_separation`: skyline band separation
- `ch05_practical_accent`: optional rooftop lamp only after sundown
- `ch06_atmosphere_grade`: warm bloom with saturation guard
- `ch07_luke_protect`: shirt/jaw/shoulder rim control
- `ch08_amira_protect`: face/scarf contour protection

Alternates:
- `dusk_desaturated` cools `ch02_world_fill` and compresses `ch06_atmosphere_grade`
- `moonlight_blue` replaces the horizon key with top-side moonlight and keeps `ch03_world_rim` narrow

## Village street night
Primary family: `moonlight_blue`
- `ch01_world_key`: cool top-side moon
- `ch02_world_fill`: low-value night ambient
- `ch03_world_rim`: silhouette rim for shoulders and scarf edges
- `ch04_background_separation`: alley depth and wall bands
- `ch05_practical_accent`: lantern/window spill pools
- `ch06_atmosphere_grade`: compressed blue night air
- `ch07_luke_protect`: strap/profile mouth read
- `ch08_amira_protect`: eyes/mouth/scarf edge survival

Alternates:
- `night_practical_mix` raises `ch05_practical_accent` and warms selective fill
- `firelight_flicker` is an insert-only modifier layered onto `ch05_practical_accent`

## Clinic interior fluorescent
Primary family: `fluorescent_clinic`
- `ch01_world_key`: overhead fluorescent key pool
- `ch02_world_fill`: wall/ceiling return fill
- `ch03_world_rim`: cabinet-edge or bed-edge separation only
- `ch04_background_separation`: curtain / wall / cabinet grouping
- `ch05_practical_accent`: task lamp or doorway spill
- `ch06_atmosphere_grade`: cool clinical clamp with green suppression
- `ch07_luke_protect`: uniform hierarchy and face warmth hold
- `ch08_amira_protect`: skin/scarf separation and mouth readability

Alternates:
- `night_practical_mix` allows warm practicals to share `ch05_practical_accent`
- `tungsten_interior` is reserved for adjacent non-clinical rooms

## Family courtyard
Primary family: `daylight_soft` by day / `sunset_warm` at dusk / `night_practical_mix` at night
- `ch01_world_key`: sky or late-sun key depending on time
- `ch02_world_fill`: courtyard wall bounce
- `ch03_world_rim`: soft edge separation against walls/trees
- `ch04_background_separation`: archway and depth pockets
- `ch05_practical_accent`: lantern/window/domestic spill
- `ch06_atmosphere_grade`: warm domestic softness or cool evening compression
- `ch07_luke_protect`: silhouette/value separation under soft domestic warmth
- `ch08_amira_protect`: face-framing/scarf softness with emotional clarity

## Engineering note
The runtime does not need to expose every lane to creative users initially. It only needs enough public controls to choose the profile family and accept scene-level overrides. The channel assignments here should remain internal implementation defaults.
