# 114 — Combined Engine Dependency Graph

Date: 2026-03-31

## Purpose
Turn the combined rollout bands and work packages into an execution graph that shows:
- what blocks later work
- what can be built in parallel
- which ownership tracks can move simultaneously

## Principle
The graph should be derived from the work-package map, not from ad hoc guesses.

## Node types
- `adapter`
- `runtime`
- `validation`

## Edge meaning
An edge means:
- the downstream package should not start until the upstream package is complete enough for handoff

## Parallelism rule
Packages without unmet dependencies can be built in parallel, especially when they belong to different ownership tracks.

## Report goals
The dependency graph report should identify:
- root packages
- leaf packages
- parallel-ready packages
- longest dependency chain
- invalid edges or cycles

## Engineering value
This graph is the missing bridge between:
- milestone planning
- ownership planning
- actual implementation sequencing
