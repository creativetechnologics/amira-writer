# 121 — Combined Engine Contingency Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine contingency playbook.

## Required generated outputs
- one machine-readable combined-engine contingency report

## Expected top-level fields
- `triggerPackages`
- `bandPlaybooks`
- `trackFallbacks`
- `globalContingencies`
- `valid`

## Expected trigger-package fields
- `workPackageId`
- `bandId`
- `ownerTrack`
- `riskLevel`
- `fallbackTracks`
- `immediateActions`
- `keepMovingWork`
- `exitCriteria`

## Expected band-playbook fields
- `bandId`
- `primaryBlockers`
- `adapterFallback`
- `runtimeFallback`
- `validationFallback`
- `fixtureFallback`

## Validation rules
- every trigger package must exist in the combined work-package map
- trigger packages should come from the highest-risk portion of the risk register
- fallback tracks must reconcile with the staffing map
- every band on the critical path should have a playbook entry

## Handoff expectation
The handoff bundle should carry:
- the generated contingency report
- docs explaining how to use it with the risk, staffing, and critical-path reports
