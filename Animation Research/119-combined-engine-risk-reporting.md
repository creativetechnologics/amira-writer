# 119 — Combined Engine Risk Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine risk register.

## Required generated outputs
- one machine-readable combined-engine risk report

## Expected top-level fields
- `criticalPathLength`
- `parallelReliefPackages`
- `trackConcentration`
- `programRisks`
- `riskRegister`
- `highestRiskPackages`
- `valid`

## Expected program-risk fields
- `riskId`
- `riskLevel`
- `summary`
- `trigger`
- `mitigationActions`

## Expected package-risk fields
- `riskId`
- `workPackageId`
- `bandId`
- `responsibility`
- `ownerTrack`
- `criticalPathIndex`
- `downstreamPackageCount`
- `riskLevel`
- `riskType`
- `summary`
- `mitigationActions`
- `contingencyWork`

## Validation rules
- every package in the risk register must exist in the combined work-package map
- risk entries should be sorted by severity and then by critical-path position
- highest-risk packages should come from the earliest, highest-impact portion of the critical path
- track concentration must reconcile with the staffing map
- the report should remain valid even when the program is artifact-ready; readiness does not erase schedule risk

## Handoff expectation
The handoff bundle should carry:
- the generated combined-engine risk report
- docs explaining how to use it with the dependency, staffing, and critical-path reports
