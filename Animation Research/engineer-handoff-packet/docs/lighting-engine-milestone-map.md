# 102 — Lighting Engine Milestone Map

Date: 2026-03-31

## Purpose
Turn the lighting research sandbox into a concrete implementation ladder for the future engine rollout.

## Principle
The rollout must remain engine-first, not scene-first:
- build generic adapters
- prove deterministic contracts
- widen cast/location coverage gradually
- only then expose broader production paths

## Recommended milestone ladder

### M1 — Data and adapter foundation
Build:
- `LightingProfileAdapter`
- `LightingResponseAdapter`
- `ShotLightingPlanAdapter`
- validation hooks for profiles, plans, and response metadata

Goal:
Load lighting contracts safely without affecting the current runtime.

### M2 — Single-shot deterministic relight harness
Build:
- research-only relight harness
- character/background shared-light application
- line/skin/readability protection checks

Goal:
Prove that one shot can be relit deterministically from JSON inputs.

### M3 — Mouth-aware lighting protection
Build:
- mouth/face readability protection lane integration
- angle-aware mouth survivability checks under active lighting

Goal:
Ensure the lighting engine does not break dialogue/singing readability.

### M4 — Routing-aware lighting decisions
Build:
- readiness/routing/stress cross-check bridge
- warnings when baseline routing understates lighting complexity

Goal:
Make lighting complexity influence execution strategy automatically.

### M5 — Ensemble-safe lighting
Build:
- ensemble protection lane handling
- zone/practical stress evaluation
- ensemble diff/regression safeguards

Goal:
Scale safely from hero/duet shots to controlled ensemble scenes.

### M6 — Production-grade governance
Build:
- handoff packet automation
- acceptance-matrix enforcement
- regression bundles in CI/test harnesses

Goal:
Keep the engine stable as package, lighting, and routing rules evolve.

## Gate rule
Do not advance to the next milestone until the previous milestone has fixtures, validators, and acceptance outputs.
