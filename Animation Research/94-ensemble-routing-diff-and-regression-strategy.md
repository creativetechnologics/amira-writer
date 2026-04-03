# 94 — Ensemble Routing Diff And Regression Strategy

Date: 2026-03-31

## Purpose
Define how to compare ensemble routing comparison fixtures so baseline regressions are caught before engineering routing defaults are replaced.

## Compared fixture family
- ensemble routing comparison fixtures spanning the shared-light worlds for the core hero locations

## Block-level regressions
Always block baseline replacement when:
- a required hero location disappears
- a comparison loses one of the required route modes
- participant count collapses below the expected ensemble shape
- `village-street-night` regresses to an `internal` baseline
- a 5+ participant comparison regresses to an `internal` baseline
- a baseline drops from `internal`/`hybrid` to `ai-video-fallback`

## Warn-level regressions
Warn, but do not automatically block, when:
- a baseline downgrades from `internal` to `hybrid`
- participant count decreases while staying ensemble-valid
- decision reasons shrink materially

## Bundle recommendation
Ensemble routing diff reporting should mirror the lighting/package diff flow:
1. old ensemble routing fixture
2. new ensemble routing fixture
3. machine-readable diff JSON
4. human-readable markdown summary

## First pilot policy
The handoff outputs should include:
- one passing ensemble routing diff bundle
- one regressed ensemble routing diff bundle
