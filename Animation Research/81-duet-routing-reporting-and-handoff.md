# 81 — Duet Routing Reporting And Handoff

Date: 2026-03-31

## Purpose
Define the reporting outputs that should accompany duet routing comparisons in the handoff packet.

## Required generated outputs
- one machine-readable duet routing comparison report
- one summary of baseline recommendations by location
- one list of locations where fallback is acceptable only under exceptional complexity

## Reporting rule
A location should only show `ai-video-fallback` as baseline when:
- lighting complexity and motion complexity are both high
- the internal package coverage is materially insufficient
- continuity control loss is acceptable for the scene

## Handoff expectation
The handoff bundle should carry:
- the source comparison fixture JSON
- the generated routing comparison report JSON
- a short markdown explanation embedded in the docs set
