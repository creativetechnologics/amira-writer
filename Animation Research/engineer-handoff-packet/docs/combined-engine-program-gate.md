# 108 — Combined Engine Program Gate

Date: 2026-03-31

## Purpose
Determine whether a combined rollout band is actually ready to begin, based on the presence of its required docs, fixtures, and generated outputs.

## Gate rule
A band is **ready** only when:
- all required docs exist
- all required fixtures exist
- all required generated outputs exist
- all dependency bands are already ready

## Why this matters
The rollout matrix is a plan. The program gate answers a harder question:

> “Can engineering start this band now without inventing missing research artifacts?”

## Expected report fields
- `bandCount`
- `readyBands`
- `blockedBands`
- `highestContiguousReadyBand`
- `bandStatuses`

Each band status should include:
- `bandId`
- `ready`
- `dependencyReady`
- `missingDocs`
- `missingFixtures`
- `missingOutputs`

## Engine-level rule
The gate should stay artifact-driven. It should not infer readiness from optimism or prose; it should check the actual research and handoff files on disk.
