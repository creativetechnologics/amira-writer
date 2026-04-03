# 123 — Combined Engine Band Exit Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine band-exit gate.

## Required generated outputs
- one machine-readable combined-engine band-exit report

## Expected top-level fields
- `bandCount`
- `exitReadyBands`
- `blockedBands`
- `highestExitReadyBand`
- `bandStatuses`
- `valid`

## Expected per-band fields
- `bandId`
- `bandName`
- `dependencyReady`
- `missingDocs`
- `missingFixtures`
- `missingOutputs`
- `subsystemChecks`
- `exitCriteria`
- `exitReady`

## Validation rules
- every band in the rollout matrix must appear in the band-exit report
- subsystem checks must reconcile with the rollout matrix entries
- `highestExitReadyBand` must be the last contiguous exit-ready band in rollout order
- a band cannot be exit-ready if any dependency band is not exit-ready

## Handoff expectation
The handoff bundle should carry:
- the generated band-exit report
- docs explaining how to use it with the rollout matrix, program gate, risk report, and contingency playbook
