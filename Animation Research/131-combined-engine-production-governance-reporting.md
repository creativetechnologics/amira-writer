# 131 — Combined Engine Production Governance Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine production governance dashboard.

## Required generated outputs
- one machine-readable production governance dashboard report

## Expected top-level fields
- `overallState`
- `highestContiguousReadyBand`
- `highestExitReadyBand`
- `promotionReadyBands`
- `blockedBands`
- `highestRiskPackages`
- `programRiskIds`
- `triggerPackageCount`
- `minimumReentryBand`
- `implementationTestReady`
- `topConcerns`
- `valid`

## Validation rules
- the dashboard may only be `green`, `yellow`, or `red`
- `red` requires either blocked promotion bands or one or more invalid required reports
- `green` requires all required reports valid and zero blocked promotion bands and zero top concerns
- `topConcerns` should be non-empty whenever the dashboard is `yellow` or `red`

## Handoff expectation
The handoff bundle should carry:
- the generated governance dashboard report
- docs explaining how to use it as the top-level summary above the detailed reports
