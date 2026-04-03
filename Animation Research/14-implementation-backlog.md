# 14 — Implementation Backlog (Research Sandbox)

Date: 2026-03-31

## Goal
Build everything needed to slot this system into Amira Writer later, without touching the app yet.

## Phase A — Contracts and schemas
1. character package vNext schema
2. mouth profile schema
3. motion-plan schema
4. structured asset review schema

## Phase B — Planning tools
1. asset count estimator
2. Nano Banana cost estimator
3. package readiness scorer
4. coverage gap reporter

## Phase C — AI QA loop
1. review prompt template
2. review JSON schema
3. edit-vs-regenerate decision rules
4. correction prompt generator

## Phase D — Runtime simulation tools
1. motion-plan validator
2. mouth-profile selector simulator
3. shot-routing simulator
4. package completeness checker

## Phase E — First proving-ground package
Target first package:
- **Luke hero package v1**

Build and validate:
- master sheet
- head sheet
- 2 costume packs
- core mouth profiles
- locomotion primitives
- seated / kneeling / reach / react primitives

## Validation gates
- static dialogue shot
- walk-and-talk shot
- singing medium shot
- one hard shot routed to AI video

## Recommendation
Do not start by wiring this into the app.
First finish the research-sandbox contracts, tools, and example package data so app integration becomes mostly a translation exercise.
