# 109 — Combined Engine Program Gate Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine program gate.

## Required generated outputs
- one machine-readable gate report against the current research tree

## Expected report fields
- `bandCount`
- `readyBands`
- `blockedBands`
- `highestContiguousReadyBand`
- `bandStatuses`

## Handoff expectation
The handoff bundle should carry:
- the source combined rollout matrix fixture
- the generated program gate report
- docs explaining how engineering should interpret a blocked band

## Interpretation rule
- a blocked later band does not invalidate earlier ready bands
- the highest contiguous ready band is the safest next engineering start point
