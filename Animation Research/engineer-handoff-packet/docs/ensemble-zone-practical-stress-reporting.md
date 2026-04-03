# 97 — Ensemble Zone/Practical Stress Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for ensemble zone/practical stress fixtures.

## Required generated outputs
- one machine-readable stress report
- one per-case routing-pressure summary
- one list of cases that must not remain `internal`

## Expected report fields
- `caseCount`
- `internalSafeCases`
- `hybridPressureCases`
- `fallbackPressureCases`
- `caseSummaries`

Each case summary should include:
- `shotId`
- `locationId`
- `participantCount`
- `maxBeatStress`
- `recommendedMinimumRouting`
- `blockingIssues`
- `warnings`

## Handoff expectation
The engineer handoff packet should carry:
- the source stress fixture JSON
- the generated stress report JSON
- docs explaining why zone/practical complexity can override nominal readiness
