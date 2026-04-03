# 122 — Combined Engine Band Exit Criteria

Date: 2026-03-31

## Purpose
Define explicit "done means done" conditions for each combined-engine rollout band.

## Principle
A rollout matrix says what each band needs.
A band-exit gate says whether those needs are actually satisfied strongly enough to move to the next band.

## What the exit gate should do
- inspect every combined rollout band in order
- verify that dependency bands are already exit-ready
- verify that required docs, fixtures, and generated outputs are all present
- summarize the concrete exit criteria for engineering handoff
- expose the highest fully exit-ready band

## Required per-band checks
Each band should verify:
- dependency clearance
- required document coverage
- required fixture coverage
- required output coverage
- subsystem readiness across body, mouth, and lighting

## Required per-band report fields
Each band entry should include:
- `bandId`
- `bandName`
- `dependencyReady`
- `missingDocs`
- `missingFixtures`
- `missingOutputs`
- `subsystemChecks`
- `exitCriteria`
- `exitReady`

## Why this matters
The future engine needs a stronger gate than "some artifacts exist."
Engineering should be able to ask:

> “Is this band truly done enough that the next band may begin without hidden gaps?”
