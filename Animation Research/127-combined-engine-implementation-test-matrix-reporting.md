# 127 — Combined Engine Implementation Test Matrix Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine implementation test matrix.

## Required generated outputs
- one machine-readable implementation test matrix report

## Expected top-level fields
- `changeClassCount`
- `bandCount`
- `globalValidationArtifacts`
- `testMatrix`
- `valid`

## Expected per-row fields
- `changeClassId`
- `bandId`
- `reentryBand`
- `reopened`
- `validationArtifacts`
- `missingArtifacts`
- `ready`
- `rationale`

## Validation rules
- every change class must resolve to a valid re-entry band
- every reopened band must produce a matrix row
- every listed validation artifact must exist in the handoff outputs directory for the row to be ready
- non-reopened bands should still appear explicitly with an empty validation list

## Handoff expectation
The handoff bundle should carry:
- the generated implementation test matrix report
- docs explaining how to use it with the change-impact matrix, band-exit gate, and program gate
