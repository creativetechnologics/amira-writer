# 112 — Combined Engine Staffing And Ownership Map

Date: 2026-03-31

## Purpose
Map the combined-engine work packages into practical engineering ownership tracks so future implementation can be staffed coherently.

## Ownership principle
Ownership should follow stable responsibility lanes, not individual scenes:
- **adapter track**
- **runtime track**
- **validation/governance track**
- **fixture/research-maintenance track**

## Why this matters
The work-package map says what needs to be built.
The staffing map says who should own related slices of work without causing subsystem drift.

## Recommended ownership model

### 1. Adapter track
Owns:
- package adapters
- motion adapters
- mouth adapters
- lighting adapters
- schema/version bridge work

Goal:
Keep the runtime insulated from changing research contract shapes.

### 2. Runtime track
Owns:
- body playback
- mouth playback
- lighting playback
- combined pilot harnesses
- routing handshake execution

Goal:
Turn validated contracts into deterministic execution.

### 3. Validation / governance track
Owns:
- acceptance gates
- diff/regression bundles
- routing/stress consistency checks
- readiness outputs
- program gate enforcement

Goal:
Prevent unsafe rollout and catch subsystem disagreement early.

### 4. Fixture / research-maintenance track
Owns:
- keeping example fixtures current
- updating handoff outputs
- refreshing milestone/work-package maps
- maintaining representative regression cases

Goal:
Keep engineering inputs realistic and non-stale as the design evolves.

## Rule
Every rollout band should have explicit ownership across these tracks before implementation begins.
