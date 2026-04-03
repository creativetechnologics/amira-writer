# 78 — Lighting Diff and Regression Strategy

Date: 2026-03-31

## Purpose
Define how to compare lighting-channel fixtures and duet motion-lighting fixtures so coverage regressions are caught before engineering baselines are replaced.

## Compared fixture families
- hero location profile channel maps
- duet motion-lighting packets
- optional future per-location lighting-plan revisions

## Block-level regressions
Always block baseline replacement when any of the following occur:
- a required hero location binding disappears
- a required profile family disappears
- any profile family loses one of the canonical channels `ch01`–`ch08`
- a duet motion-lighting packet for a required location disappears
- a duet packet loses its lighting-plan fixture or duet-lighting fixture
- a duet packet loses beat coverage below the minimum viable threshold

## Warn-level regressions
Warn, but do not automatically block, when:
- a location changes default profile family
- routing mode downgrades from `internal` to `hybrid`
- beat count drops while still staying above minimum
- channel fixture roles change but channel IDs remain intact

## Info-level changes
Track, but do not flag as regressions:
- new profile families added experimentally
- new hero locations added outside the first five
- new duet packets added for alternates or insert coverage

## Bundle recommendation
Lighting regression reporting should mirror the package diff flow:
1. old fixture baseline
2. new fixture candidate
3. machine-readable diff JSON
4. human-readable markdown summary
5. explicit acknowledgement for BLOCK regressions

## First pilot policy
Before engineering starts live implementation, every handoff output rebuild should include:
- one passing lighting diff example
- one failing/regressed lighting diff example
- a machine-readable report for both
