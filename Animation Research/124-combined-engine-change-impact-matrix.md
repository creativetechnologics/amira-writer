# 124 — Combined Engine Change-Impact Matrix

Date: 2026-03-31

## Purpose
Define how future engineering should determine which rollout bands must be re-opened after a contract, schema, runtime, or validation change.

## Principle
Not every change forces the full program back to band one.
The engine needs a deterministic re-entry rule that says:

> “Given this kind of change, what is the earliest rollout band that must be re-opened, and which later bands must be re-validated?”

## What the matrix should do
- classify change events by type and subsystem
- compute the earliest re-entry band
- list every later band that must be reopened
- identify the work packages and outputs that must be re-checked
- preserve a reusable engine-level rule instead of a hero-specific scenario

## Required event inputs
Each change event should include:
- `eventId`
- `changeType`
- `subsystem`
- `summary`

## Required report fields per event
Each event result should include:
- `eventId`
- `changeType`
- `subsystem`
- `reentryBand`
- `reopenedBands`
- `impactedWorkPackages`
- `recheckOutputs`
- `rationale`

## Baseline re-entry rules
- shared schema or shared adapter-contract change → re-enter at `B1`
- shared runtime-contract or runtime-behavior change → re-enter at `B2`
- body runtime change → re-enter at `B2`
- mouth runtime change → re-enter at `B3`
- lighting runtime change → re-enter at `B2`
- shared validation or governance rule change → re-enter at `B1`
- body validation rule change → re-enter at `B2`
- mouth validation rule change → re-enter at `B3`
- lighting validation rule change → re-enter at `B3`

## Why this matters
The combined rollout is now artifact-complete.
The missing operational question is what happens when engineering changes one of the contracts after implementation begins.
The change-impact matrix prevents ad hoc re-entry decisions and preserves rollout discipline.
