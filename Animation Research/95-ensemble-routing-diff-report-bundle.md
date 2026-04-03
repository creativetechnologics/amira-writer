# 95 — Ensemble Routing Diff Report Bundle

Date: 2026-03-31

## Purpose
Define the review bundle for ensemble routing comparison revisions.

## Bundle contents
An ensemble routing diff bundle should contain:
- old ensemble routing comparison fixture JSON
- new ensemble routing comparison fixture JSON
- `ensemble_routing_diff_report.json`
- `ensemble_routing_diff_report.md`

## Regression classes
Block on:
- missing required location coverage
- missing required route modes
- baseline collapsing to `ai-video-fallback`
- `village-street-night` or 5+ participant ensembles baselining `internal`

Warn on:
- `internal` → `hybrid` baseline downgrades
- participant count reductions
- reduced decision rationale

## Handoff expectation
The engineer handoff packet should carry:
- a passing ensemble routing diff bundle
- a regressed ensemble routing diff bundle
