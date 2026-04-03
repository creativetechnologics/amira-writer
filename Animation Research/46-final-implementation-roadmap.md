# 46 — Final Condensed Implementation Roadmap

Date: 2026-03-31

## Purpose
Give a concise staged roadmap for when the research sandbox eventually begins moving into implementation.

## Stage 1 — Safe adapters
Build:
- PackageManifestAdapter
- MotionPlanAdapter
- MouthOverlayAdapter
- AssetReviewAdapter
- ReadinessAdapter

Goal:
Load research fixtures without touching the current runtime path.

## Stage 2 — First internal pilot
Build one Luke dialogue pilot with:
- hero-ready package
- pilot packet
- front/quarter-turn mouth overlays
- internal routing only

Goal:
Prove the package + motion + mouth architecture works at all.

## Stage 3 — Expand controlled coverage
Add:
- more mouth angle families
- locomotion coverage
- second costume packs
- better QA/review persistence

Goal:
Handle normal dialogue and restrained singing scenes reliably.

## Stage 4 — Routing intelligence
Add:
- readiness-to-routing bridge
- larger shot library
- hybrid decision rules

Goal:
Route shots sanely without overusing AI-video fallback.

## Stage 5 — Broader production readiness
Add:
- more ensemble handling
- richer emotion presets
- upgrade tooling
- stronger package diff/regression guards

Goal:
Support a larger share of the film safely.
