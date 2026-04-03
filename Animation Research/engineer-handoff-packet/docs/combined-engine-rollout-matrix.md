# 106 — Combined Engine Rollout Matrix

Date: 2026-03-31

## Purpose
Align the body engine, mouth engine, and lighting engine into one staged implementation program for the future full animation engine.

## Principle
The full engine should roll out by **coordinated milestone bands**, not by isolated subsystem work that drifts out of sync.

Each band should answer:
- what the body engine must support
- what the mouth engine must support
- what the lighting engine must support
- what cross-subsystem contract becomes mandatory

## Rollout bands

### B1 — Contract and adapter foundation
- **Body**: package manifest + motion-plan adapters
- **Mouth**: mouth profile + preset adapters
- **Lighting**: profile/response/plan adapters
- **Cross-system contract**: fixture loading, schema validation, additive persistence

### B2 — Single-character deterministic pilot
- **Body**: one dialogue blocking harness
- **Mouth**: speech-only overlay harness
- **Lighting**: deterministic single-shot relight harness
- **Cross-system contract**: one character, one costume, one shot packet

### B3 — Singing and readability
- **Body**: stable restrained acting playback
- **Mouth**: singing timing layer
- **Lighting**: mouth/face readability protection
- **Cross-system contract**: dialogue/singing acceptance under active light

### B4 — Routing-aware intelligence
- **Body**: readiness-to-routing bridge
- **Mouth**: survivability reporting by angle/performance mode
- **Lighting**: routing/stress consistency layer
- **Cross-system contract**: route decisions cannot ignore subsystem minima

### B5 — Ensemble-safe scaling
- **Body**: controlled multi-character blocking
- **Mouth**: ensemble-safe coverage expectations
- **Lighting**: ensemble stress and consistency safeguards
- **Cross-system contract**: ensemble routing floors and regression checks

### B6 — Production governance
- **Body**: diff/regression + upgrade policy
- **Mouth**: diff/regression + acceptance matrix
- **Lighting**: diff/regression + acceptance matrix
- **Cross-system contract**: handoff bundle automation and CI/test-harness style validation

## Gate rule
Do not move to the next band until all three subsystems have fixture coverage and generated outputs for the current band.
