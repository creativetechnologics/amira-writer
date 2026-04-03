# 21 — Adapter Layer and Compatibility Plan

Date: 2026-03-31

## Purpose
Describe how the research artifacts should eventually connect to the existing Animate implementation without a destructive rewrite.

## Compatibility principle
Add adapter layers first. Do not force the current app to understand every new concept natively on day one.

## Proposed adapters

### PackageManifestAdapter
Converts the vNext research package manifest into the smaller runtime concepts that current Animate can understand.

### MotionPlanAdapter
Converts sparse LLM-authored plans into timeline-safe runtime instructions.

### MouthOverlayAdapter
Converts mouth plans into mouth-layer swaps, viseme timing, and placement updates.

### AssetReviewAdapter
Converts structured AI review JSON into status flags, retry requests, and promotion decisions.

## How this reduces risk
- old package flow can remain intact during experimentation
- new vNext manifests can coexist beside current manifests
- research-only schemas can be validated before any UI or persistence work changes

## Recommended first pilot later
Pick one narrow case:
- one hero character
- one costume
- front + quarter-turn dialogue
- speech only, then singing later

That pilot would validate:
- package manifest loading
- sparse plan playback
- mouth overlay timing
- QA/review storage

## What should remain outside the adapter at first
- AI video shot routing
- complex cloth simulation
- high-complexity locomotion variants
- automatic corrective generation

## Planning takeaway
The adapters should absorb the shape mismatch between:
- current Animate data structures
- future package/runtime contracts

This keeps the research work slot-in ready without forcing an immediate rewrite.
