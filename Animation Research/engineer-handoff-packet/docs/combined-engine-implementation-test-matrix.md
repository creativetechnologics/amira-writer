# 126 — Combined Engine Implementation Test Matrix

Date: 2026-03-31

## Purpose
Map each rollout band and major change class to the exact validation artifacts engineering should run before re-promoting that band.

## Principle
The change-impact matrix tells engineering which bands reopen.
The implementation test matrix tells engineering what to run to close those bands again.

## What the matrix should do
- classify major engine change classes
- compute the re-entry band for each class
- enumerate every affected rollout band
- list the exact validation artifacts required before that band can be re-promoted
- verify that those artifacts already exist in the handoff output bundle

## Major change classes
The matrix should support reusable engine-level classes such as:
- shared schema changes
- shared adapter-contract changes
- body runtime changes
- mouth runtime changes
- lighting runtime changes
- shared validation/governance changes
- mouth validation changes
- lighting validation changes

## Required per-row fields
Each matrix row should include:
- `changeClassId`
- `bandId`
- `reentryBand`
- `reopened`
- `validationArtifacts`
- `missingArtifacts`
- `ready`
- `rationale`

## Required global fields
The report should also expose:
- `changeClassCount`
- `bandCount`
- `globalValidationArtifacts`
- `testMatrix`
- `valid`

## Why this matters
Once the future engine is live, engineering will need a deterministic answer to:

> “We changed this contract. Which bands reopen, and which test artifacts must pass before each band is promoted again?”

The implementation test matrix answers that question without improvisation.
