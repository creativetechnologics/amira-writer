# 70 — Hero Location Lighting Profile Map

Date: 2026-03-31

## Purpose
Map the hero characters to the key locations, reusable lighting profile families, and the concrete fixture/channel assignments that should survive into engineering.

## Shared channel contract
Every hero lighting setup should draw from the same compact channel family so the runtime can relight deterministically:
- `ch01_world_key` — dominant world key direction/value structure
- `ch02_world_fill` — environment bounce / global fill
- `ch03_world_rim` — horizon or edge separation for shared silhouettes
- `ch04_background_separation` — building / wall / sky / depth separation
- `ch05_practical_accent` — window, lamp, doorway, lantern, or practical spill
- `ch06_atmosphere_grade` — dust, haze, night air, fluorescent flatness, or sunset bloom
- `ch07_luke_protect` — local readable protection for Luke's face / utility costume hierarchy
- `ch08_amira_protect` — local readable protection for Amira's face / scarf framing

## Profile families with channel assignments

### `daylight_soft`
Primary usage:
- district clinic exterior
- family courtyard day
- clinic-adjacent exteriors

Recommended fixture/channel assignments:
- `ch01_world_key` → sky-soft key from open sky or screen-left sun bounce
- `ch02_world_fill` → facade / courtyard wall bounce
- `ch03_world_rim` → low-intensity shoulder or head edge from opposite sky side
- `ch04_background_separation` → facade / alley value shaping
- `ch05_practical_accent` → doorway bounce only if present
- `ch06_atmosphere_grade` → light dust haze / daylight palette clamp
- `ch07_luke_protect` → pocket / satchel / jaw readability lift
- `ch08_amira_protect` → face-framing / scarf-edge softness lift

### `sunset_warm`
Primary usage:
- rooftop sunset
- family courtyard sunset
- district clinic exterior late afternoon

Recommended fixture/channel assignments:
- `ch01_world_key` → low warm horizon key
- `ch02_world_fill` → warm wall bounce plus weak cool sky counter-fill
- `ch03_world_rim` → sky-line rim on silhouette edge
- `ch04_background_separation` → horizon / parapet / courtyard wall banding
- `ch05_practical_accent` → window or courtyard practical only after sun falls
- `ch06_atmosphere_grade` → warm bloom clamp with saturation guard
- `ch07_luke_protect` → jaw / shoulder / shirt-value protection
- `ch08_amira_protect` → face warmth / scarf contour protection

### `moonlight_blue`
Primary usage:
- village street night
- rooftop post-sunset
- district clinic exterior night

Recommended fixture/channel assignments:
- `ch01_world_key` → cool top-side moon key
- `ch02_world_fill` → minimal ambient night fill
- `ch03_world_rim` → cool silhouette rim for travel / walk-and-talk readability
- `ch04_background_separation` → doorway / wall / roofline split against night sky
- `ch05_practical_accent` → lantern or spill only where motivated
- `ch06_atmosphere_grade` → blue night compression with mouth-read guard
- `ch07_luke_protect` → strap / shoulder / profile mouth visibility lift
- `ch08_amira_protect` → eye / mouth / scarf-edge survival lift

### `fluorescent_clinic`
Primary usage:
- clinic interior fluorescent room
- medical dialogue
- emotional close-up coverage

Recommended fixture/channel assignments:
- `ch01_world_key` → overhead fluorescent pool
- `ch02_world_fill` → cool room bounce
- `ch03_world_rim` → subtle bed-edge / cabinet-edge rim only
- `ch04_background_separation` → wall / curtain / cabinet value shaping
- `ch05_practical_accent` → task light / doorway spill if motivated
- `ch06_atmosphere_grade` → clinical desaturation and green-control clamp
- `ch07_luke_protect` → uniform hierarchy / face warmth preservation
- `ch08_amira_protect` → skin deadening prevention / scarf separation

### `night_practical_mix`
Primary usage:
- family courtyard night
- village street practical pools
- clinic-adjacent night exteriors

Recommended fixture/channel assignments:
- `ch01_world_key` → low moon or residual sky key
- `ch02_world_fill` → mixed warm/cool ambient fill
- `ch03_world_rim` → selective edge split from practical opposite the moon side
- `ch04_background_separation` → depth pockets around walls, doors, and alleys
- `ch05_practical_accent` → lamps, window spill, lantern pools
- `ch06_atmosphere_grade` → warm/cool coexistence clamp
- `ch07_luke_protect` → silhouette and pocket hierarchy under mixed values
- `ch08_amira_protect` → face/mouth/scarf read under mixed practical spill

## Luke Hart
Likely dominant locations:
- district clinic exterior
- clinic interior fluorescent room
- village street at night
- checkpoint / travel exteriors later

Most important profile families:
- `daylight_soft`
- `fluorescent_clinic`
- `sunset_warm`
- `moonlight_blue`
- `dust_storm_flat`

Luke-specific channel emphasis:
- `ch07_luke_protect` should prioritize jawline, satchel strap, pocket value split, and mouth visibility
- on `sunset_warm`, Luke needs shirt / jacket value control before extra facial warming
- on `moonlight_blue`, Luke's silhouette hierarchy should be protected before adding broad fill

## Amira Nazari
Likely dominant locations:
- family courtyard / home exterior
- rooftop at sunset
- village street at night
- clinic-adjacent exteriors/interiors

Most important profile families:
- `daylight_soft`
- `sunset_warm`
- `night_practical_mix`
- `moonlight_blue`
- `fluorescent_clinic`

Amira-specific channel emphasis:
- `ch08_amira_protect` should prioritize brow/eye/mouth readability, scarf contour, and gentle face-framing softness
- on `sunset_warm`, Amira needs saturation guard before warmth boost
- on `fluorescent_clinic`, Amira needs skin/scarf separation before any room-level desaturation increase

## Location bindings

### District clinic exterior
Profiles:
- `daylight_soft` as default day profile
- `sunset_warm` for late-day emotional coverage
- `moonlight_blue` for tense night exterior

Channel emphasis:
- `ch01_world_key` / `ch02_world_fill` from clinic facade and sky bounce
- `ch07_luke_protect` for utility cloth readability
- `ch08_amira_protect` for facial contour and scarf edge

### Rooftop sunset
Profiles:
- `sunset_warm` as default
- `dusk_desaturated` as cooler alternate
- `moonlight_blue` for post-sunset extension

Channel emphasis:
- `ch03_world_rim` becomes critical against sky band
- `ch07_luke_protect` favors jaw / shoulder rim
- `ch08_amira_protect` favors face / scarf contour under warm edge light

### Village street night
Profiles:
- `moonlight_blue` as default
- `night_practical_mix` for motivated pools
- `firelight_flicker` only as scene-specific special case

Channel emphasis:
- `ch05_practical_accent` must stay motivated and sparse
- `ch07_luke_protect` preserves profile mouth read and strap silhouette
- `ch08_amira_protect` preserves eyes, mouth, and scarf edge in low-value scenes

### Clinic interior fluorescent
Profiles:
- `fluorescent_clinic` as default
- `night_practical_mix` for reduced-power or side-room scenes
- `tungsten_interior` only in non-clinical adjacencies

Channel emphasis:
- `ch01_world_key` stays overhead and cool
- `ch07_luke_protect` preserves uniform hierarchy
- `ch08_amira_protect` prevents facial deadening and scarf flattening

### Family courtyard
Profiles:
- `daylight_soft` for day
- `sunset_warm` for emotional late-afternoon scenes
- `night_practical_mix` for evening / domestic scenes

Channel emphasis:
- `ch02_world_fill` and `ch05_practical_accent` drive domestic softness
- `ch07_luke_protect` preserves masculine silhouette under warm domestic light
- `ch08_amira_protect` preserves face-framing and soft scarf read

## Shared hero conclusion
The first lighting implementation should prioritize shared reusable profiles across the hero locations instead of building one-off location grading for every scene. The channel contract above is the bridge between the high-level profile families and future runtime relight code.
