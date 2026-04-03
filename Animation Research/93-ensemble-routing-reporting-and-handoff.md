# 93 — Ensemble Routing Reporting And Handoff

Date: 2026-03-31

## Purpose
Define the reporting outputs that should accompany ensemble routing comparisons in the handoff packet.

## Required generated outputs
- one machine-readable ensemble routing comparison report
- one baseline summary by location
- one summary of locations that remain internal-capable for controlled ensemble staging
- one summary of locations that should stay hybrid-biased for ensemble density reasons

## Reporting rule
A location should only show `internal` as the baseline when:
- ensemble density remains manageable
- the shared light world is stable
- the package/readiness floor is high enough for retakes
- practical channels do not dominate the shot

## Handoff expectation
The handoff bundle should carry:
- the source ensemble comparison fixture JSON
- the generated comparison report JSON
- short docs explaining why the baseline route differs from duet routing in the same light world
