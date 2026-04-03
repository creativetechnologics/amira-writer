# 118 — Combined Engine Risk Register

Date: 2026-03-31

## Purpose
Capture the schedule and integration risks most likely to slow the future animation-engine rollout.

## Principle
The combined engine already has rollout bands, work packages, staffing, dependencies, and a critical path.
The missing layer is a risk register that turns those structures into actionable schedule guidance.

## What the risk register should do
- identify the work packages on or near the critical path that carry the most schedule pressure
- show why each package is risky
- show which ownership track is most affected
- suggest mitigation and contingency work that can proceed without widening the critical path
- highlight program-level risks such as single-root dependency, track concentration, or weak parallel relief

## Risk sources
The register should read from:
- combined work packages
- staffing / ownership map
- dependency structure
- critical-path summary

## Required package-level fields
Each risk entry should include:
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

## Program-level risks
The register should also summarize broader risks such as:
- single-root or weak-foundation chokepoints
- overly long serial dependency chains
- concentration of critical-path ownership in one track
- too few parallel-relief packages early in the program

## Why this matters
The dependency report explains sequencing.
The critical-path report explains priority.
The risk register explains where schedule failure is most likely and what engineering can do about it before integration begins.
