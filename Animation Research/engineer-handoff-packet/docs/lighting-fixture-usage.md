# 64 — Lighting Handoff Fixture Usage

Date: 2026-03-31

## Purpose
Explain how engineers should use the new lighting fixtures inside the handoff packet.

## Included fixture roles

### `sample_lighting_profile.json`
Canonical reusable lighting profile example.

### `sample_lighting_response_profiles.json`
Material-response catalog example for both characters and backgrounds.

### `sample_shot_lighting_plan.json`
Shot-specific lighting plan example.

### `sample_lighting_review.json`
Structured lighting QA example.

### `sample_script_lighting_cues.json`
Example script-level semantic cues that should seed a lighting plan.

## Expected engineering flow
1. ingest the script cue fixture
2. derive or validate the shot lighting plan
3. resolve response profiles by asset material tags
4. apply the lighting runtime
5. run or simulate the lighting QA gate
6. record outputs into the handoff bundle outputs directory

## Minimal validation commands
- lighting profile report
- lighting plan check
- lighting review gate
- script lighting seed
- acceptance matrix check

## Why these fixtures matter
They allow lighting integration work to begin with deterministic, audited inputs instead of requiring immediate live asset generation.
