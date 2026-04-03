# 120 — Combined Engine Contingency Playbook

Date: 2026-03-31

## Purpose
Turn the combined-engine risk register into explicit fallback execution plans for the future engineering program.

## Principle
A risk register explains what is dangerous.
A contingency playbook explains what to do the moment a critical-path package slips.

## What the playbook should do
- identify the highest-risk trigger packages
- define immediate fallback work by band and track
- preserve progress on validation, fixtures, and governance when runtime or adapter work slips
- keep the longest serial chain from widening unnecessarily

## Inputs
The playbook should derive from:
- the combined work-package map
- the staffing / ownership map
- the combined-engine risk report

## Required trigger-package fields
Each trigger package in the playbook should include:
- `workPackageId`
- `bandId`
- `ownerTrack`
- `riskLevel`
- `fallbackTracks`
- `immediateActions`
- `keepMovingWork`
- `exitCriteria`

## Required band-playbook fields
Each band playbook should include:
- `bandId`
- `primaryBlockers`
- `adapterFallback`
- `runtimeFallback`
- `validationFallback`
- `fixtureFallback`

## Why this matters
A future engineering team should not need to invent recovery strategy under schedule pressure.
The contingency playbook should already say:

> “If this package slips, what keeps moving, who owns it, and what must be true before we resume the main line?”
