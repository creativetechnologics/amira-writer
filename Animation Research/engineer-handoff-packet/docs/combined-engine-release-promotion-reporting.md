# 129 — Combined Engine Release Promotion Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine release/promotion checklist.

## Required generated outputs
- one machine-readable combined-engine release promotion report

## Expected top-level fields
- `targetBandCount`
- `promotionReadyBands`
- `blockedBands`
- `promotionChecklist`
- `valid`

## Expected per-band fields
- `bandId`
- `promotionReady`
- `exitReady`
- `programGateReady`
- `riskReviewed`
- `contingencyReady`
- `changeImpactReady`
- `implementationTestReady`
- `requiredReports`
- `blockers`
- `warnings`

## Validation rules
- every target band must appear in the promotion checklist
- a blocked band must list at least one blocker
- a promotion-ready band may still list warnings, but may not list blockers
- required reports must exist and be valid for the checklist to pass

## Handoff expectation
The handoff bundle should carry:
- the generated release promotion report
- docs explaining how to use it with the band-exit gate, risk report, contingency playbook, change-impact matrix, and implementation test matrix
