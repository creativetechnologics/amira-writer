# 117 — Combined Engine Critical-Path Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine critical-path summary.

## Required generated outputs
- one machine-readable critical-path report

## Expected report fields
- `criticalPathLength`
- `criticalPath`
- `topPriorityPackages`
- `parallelReliefPackages`

## Validation rules
- the critical path must be a valid dependency chain
- top-priority packages should come from the earliest segment of the critical path
- parallel relief packages should not be on the critical path and should have no unmet upstream blockers beyond the current frontier

## Handoff expectation
The handoff bundle should carry:
- the generated critical-path report
- docs explaining how to use it with the dependency and staffing reports
