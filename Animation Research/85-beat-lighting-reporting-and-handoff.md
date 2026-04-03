# 85 — Beat Lighting Reporting And Handoff

Date: 2026-03-31

## Purpose
Define how beat-level zone/practical translation outputs should be audited and carried in the handoff bundle.

## Required generated outputs
- one machine-readable beat-lighting plan JSON
- one machine-readable audit of that plan
- one handoff fixture showing a duet scene with multiple beats and changing emphasis

## Validation rules
A valid beat-lighting plan must:
- reference an existing location plan
- only activate channels allowed by the location plan
- keep the same shared light world across beats
- declare protection channels when the beat is dialogue or singing focused

## Handoff expectation
The engineer handoff packet should contain one beat-lighting example fixture and its audit output so the future runtime team can test beat-to-beat relight continuity immediately.
