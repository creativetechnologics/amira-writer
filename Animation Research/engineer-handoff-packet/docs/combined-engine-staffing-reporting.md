# 113 — Combined Engine Staffing Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine staffing and ownership map.

## Required generated outputs
- one machine-readable staffing report

## Expected report fields
- `workPackageCount`
- `tracks`
- `packagesByTrack`
- `bandsCoveredByTrack`
- `invalidAssignments`

## Validation rules
- every work package must map to exactly one primary ownership track
- every band must include at least:
  - one adapter-owned package
  - one runtime-owned package
  - one validation/governance-owned package
- fixture/research-maintenance may span multiple bands as support ownership

## Handoff expectation
The handoff bundle should carry:
- the staffing/ownership fixture
- the generated staffing report
- docs explaining how the tracks align with the work-package map
