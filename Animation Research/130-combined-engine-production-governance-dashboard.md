# 130 — Combined Engine Production Governance Dashboard

Date: 2026-03-31

## Purpose
Provide one compact production-governance surface summarizing the full engine state in a single report.

## Principle
The sandbox now has many individual reports:
- program gate
- band exit gate
- risk register
- contingency playbook
- change-impact matrix
- implementation test matrix
- release promotion checklist

Engineering still needs one place to answer:

> “What is the current overall state of the engine program, and what should we worry about first?”

## What the dashboard should do
- summarize the current rollout readiness state
- summarize the current highest contiguous ready/exit-ready bands
- summarize highest-risk packages and key program risks
- summarize trigger-package contingency coverage
- summarize change-impact re-entry sensitivity
- summarize implementation-test readiness
- summarize release-promotion status
- produce one overall governance state and a short list of top concerns

## Required dashboard fields
The dashboard should expose:
- `overallState`
- `highestContiguousReadyBand`
- `highestExitReadyBand`
- `promotionReadyBands`
- `blockedBands`
- `highestRiskPackages`
- `programRiskIds`
- `triggerPackageCount`
- `minimumReentryBand`
- `implementationTestReady`
- `topConcerns`
- `valid`

## Governance state rules
- `green` when all core reports are valid and no promotion bands are blocked
- `yellow` when promotion is still possible but high-severity risks or broad re-entry sensitivity remain
- `red` when any required report is invalid or any target promotion band is blocked

## Why this matters
A future engineering team should not have to open six or seven reports to understand the current program posture.
The governance dashboard should provide the one-screen summary.
