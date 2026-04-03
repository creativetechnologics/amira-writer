# 115 — Combined Engine Dependency Reporting

Date: 2026-03-31

## Purpose
Define the reporting output for the combined-engine execution/dependency graph.

## Required generated outputs
- one machine-readable dependency-graph report

## Expected report fields
- `workPackageCount`
- `rootPackages`
- `leafPackages`
- `parallelReadyLayers`
- `longestDependencyChain`
- `invalidPackages`
- `hasCycle`

## Validation rules
- every dependency must point to an existing work package
- the graph must be acyclic
- at least one root package must exist
- the report should expose which packages can begin in parallel at each layer

## Handoff expectation
The handoff bundle should carry:
- the source work-package fixture
- the generated dependency report
- docs explaining how to use the graph for sequencing and staffing
