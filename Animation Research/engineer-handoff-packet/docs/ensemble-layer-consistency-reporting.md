# 101 — Ensemble Layer Consistency Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for ensemble readiness/routing/stress consistency checks.

## Required generated outputs
- one machine-readable consistency report
- one passing example
- one regressed example

## Expected report fields
- `caseCount`
- `blockingLocations`
- `warningLocations`
- `caseSummaries`

Each case summary should include:
- `locationId`
- `readinessRecommendedRouting`
- `comparisonBaselineRouting`
- `stressMinimumRouting`
- `consensusMinimumRouting`
- `blockingIssues`
- `warnings`

## Reporting rule
- a passing example should show no blocking disagreements
- a regressed example should demonstrate how the cross-check catches under-conservative baseline routes

## Handoff expectation
The handoff bundle should include the source fixtures and generated consistency reports so future engineering work can verify that readiness, routing, and stress logic stay coherent.
