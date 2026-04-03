# 17 — Character Package Build Playbook

Date: 2026-03-31

## Purpose
Define the practical step-by-step workflow for building a feature-grade character package using AI-heavy generation plus structured QA.

## Package build sequence

### Step 0 — Identity lock
Create:
- approved face reference set
- approved master sheet
- approved head turnaround sheet

Stop here until identity drift is acceptably low.

### Step 1 — Costume packs
For each costume, generate:
- costume master sheet
- 6-pose body turnaround sheet
- detail / accessory sheet
- optional overlay references

### Step 2 — Core runtime assets
Generate or derive:
- default blocking poses
- gesture bank
- walk / stop / turn primitives
- reach / point / hold / react primitives
- blinking / gaze variants

### Step 3 — Mouth package
Per head angle family, create:
- neutral closed
- rest-open
- A/I
- E
- O/U
- wide open / belting
- closed smile / grin
- tense / clenched
- M/B/P contact
- F/V contact (if needed)
- scream / cry / extreme emotional overrides for heroes

### Step 4 — QA and correction
For every asset family:
- run AI review
- classify approve / edit / regenerate / escalate
- keep correction history
- never approve a sheet that cannot serve as a source of truth later

### Step 5 — Readiness gate
Use `tools/package_readiness_model.py` and human review to decide if the package is:
- blocking-ready
- dialogue-ready
- performance-ready
- production-ready

## Recommended asset minimums

### Hero
- 1 approved identity/master sheet
- 1 approved head sheet
- 1 body sheet per costume
- 12–20 blocking/gesture primitives
- 10–16 mouth shapes across key angle families
- 4–10 accessory/prop states
- 4–10 corrective / special-case assets

### Supporting
- fewer gesture and corrective assets
- same basic sheet structure
- smaller mouth profile set acceptable if shot usage is narrow

## AI correction rules
Use edit mode when:
- pose is right but clothing detail is off
- anatomy is mostly correct and drift is local
- mouth placement is close but needs cleanup

Use full regeneration when:
- identity is wrong
- angle is wrong
- silhouette is wrong
- body construction is broken
- costume family drifted badly

## Production rule
Every future generation should be driven from:
1. approved master sheet
2. approved head sheet
3. approved costume sheet
4. approved accessory/detail refs

Do not let later generations pull from arbitrary loose images unless they have been promoted into the reference pack.
