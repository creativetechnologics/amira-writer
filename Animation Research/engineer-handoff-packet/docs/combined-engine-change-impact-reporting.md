# 125 — Combined Engine Change-Impact Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine change-impact matrix.

## Required generated outputs
- one machine-readable combined-engine change-impact report

## Expected top-level fields
- `eventCount`
- `minimumReentryBand`
- `impactMatrix`
- `bandsReopened`
- `valid`

## Expected per-event fields
- `eventId`
- `changeType`
- `subsystem`
- `reentryBand`
- `reopenedBands`
- `impactedWorkPackages`
- `recheckOutputs`
- `rationale`

## Validation rules
- every change event must resolve to a valid re-entry band
- reopened bands must be contiguous from the re-entry band through the end of the rollout
- impacted work packages must exist in the combined work-package map
- recheck outputs must exist in the handoff outputs directory once rebuilt

## Handoff expectation
The handoff bundle should carry:
- the generated change-impact report
- docs explaining how to use it with the rollout matrix, band-exit gate, risk report, and contingency playbook
