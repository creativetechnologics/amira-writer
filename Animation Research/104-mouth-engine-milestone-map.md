# 104 — Mouth Engine Milestone Map

Date: 2026-03-31

## Purpose
Turn the mouth-engine research sandbox into a concrete rollout ladder for future implementation.

## Principle
Build the mouth subsystem as its own engine:
- timing-driven
- angle-aware
- layered over body animation
- validated by fixtures before runtime adoption

## Recommended milestone ladder

### M1 — Data and profile foundation
Build:
- `MouthProfileAdapter`
- viseme-family loader
- angle-family loader
- preset/modifier loader

Goal:
Load mouth contracts safely without disturbing the current runtime.

### M2 — Speech-only mouth harness
Build:
- speech viseme timeline harness
- anchor placement checks
- front + quarter-turn mouth playback

Goal:
Prove basic dialogue playback with deterministic mouth swaps.

### M3 — Singing timing layer
Build:
- sustained-vowel timing rules
- phrase attack/release behavior
- singing-specific preset application

Goal:
Reach anime-caliber lyric timing without rebuilding the body engine.

### M4 — Angle and emotion scaling
Build:
- profile-family simplification
- emotion modifiers
- performance-mode modifiers

Goal:
Scale the same mouth system across front, quarter, and profile views.

### M5 — Lighting-aware mouth survivability
Build:
- mouth readability checks under active lighting
- face/mouth protection interaction
- beat-level mouth survivability reporting

Goal:
Ensure lighting does not destroy lyric/dialogue readability.

### M6 — Production-grade governance
Build:
- mouth diff/regression bundles
- acceptance-matrix enforcement
- handoff-output automation

Goal:
Keep mouth timing, coverage, and readability stable as packages evolve.

## Gate rule
Do not move to the next milestone until the current one has fixtures, validators, and handoff outputs.
