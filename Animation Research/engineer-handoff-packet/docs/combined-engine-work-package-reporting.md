# 111 — Combined Engine Work-Package Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine work-package map.

## Required generated outputs
- one machine-readable work-package report

## Expected report fields
- `bandCount`
- `workPackageCount`
- `packagesByBand`
- `packagesByResponsibility`
- `packagesBySubsystem`
- `invalidPackages`

## Validation rules
- every band must have at least one adapter package
- every band must have at least one runtime package
- every band must have at least one validation package
- dependencies must reference existing work packages

## Handoff expectation
The handoff bundle should carry:
- the source work-package fixture
- the generated work-package report
- docs explaining how engineering can split implementation by ownership
