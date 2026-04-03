# 61 — Material Response Library and Asset Tagging

Date: 2026-03-31

## Purpose
Define how individual assets declare their lighting behavior so a relight can be smart instead of generic.

## Core idea
Every runtime-relevant asset family should carry a material-response tag.

Examples:
- skin
- hair-dark
- hair-light
- sclera
- iris
- cotton-uniform
- canvas-strap
- leather-boot
- brass-metal
- concrete
- plaster
- sand-dust
- sky

## Why this matters
The same sunset profile should not affect:
- skin
- white cloth
- dark hair
- concrete

in the exact same way.

Without response metadata, relight becomes a blunt tint pass that destroys:
- identity
- costume readability
- line art
- depth clarity

## Recommended fields per response tag
- `id`
- `materialFamily`
- `lineProtection`
- `skinToneProtection`
- `tintSensitivity`
- `shadowStrength`
- `highlightClamp`
- `saturationClamp`
- `allowEmissiveBoost`
- `notes`

## Recommended asset tagging policy
For pilot-scale work, each asset should reference:
- one primary material-response tag
- optional secondary tags if the asset mixes materials

### Character examples
- face shell -> `skin`
- eyebrows -> `hair-dark`
- medic shirt -> `cotton-uniform`
- satchel strap -> `canvas-strap`

### Background examples
- clinic wall -> `concrete`
- sky layer -> `sky`
- street dust overlay -> `sand-dust`

## Fallback behavior
If an asset has no explicit material-response tag:
- mark it as lighting-incomplete
- allow draft rendering
- block production-ready status for lighting-dependent shots

## Practical rule
Do not require hyper-granular metadata on day one.
Start with a compact material library and expand only when the relight results prove it necessary.
