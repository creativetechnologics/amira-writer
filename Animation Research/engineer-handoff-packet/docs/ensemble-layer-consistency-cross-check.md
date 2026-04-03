# 100 — Ensemble Layer Consistency Cross-Check

Date: 2026-03-31

## Purpose
Cross-check the three ensemble routing layers so the sandbox can detect when they disagree about the minimum safe route for a location:
- ensemble beat-lighting readiness
- ensemble routing comparison baseline
- ensemble zone/practical stress minimum

## Engine-level rule
The cross-check must stay location- and participant-driven. It should never depend on specific hero names; fixtures may use current hero locations only as coverage.

## Inputs per location
- `locationId`
- `readinessRecommendedRouting`
- `comparisonBaselineRouting`
- `stressMinimumRouting`
- optional notes/reasons

## Core comparison logic
- derive a `consensusMinimumRouting` as the most conservative of the three
- flag a BLOCK when either readiness or baseline routing is **less conservative** than the stress minimum
- flag a WARN when readiness and baseline disagree but both remain at least as conservative as the stress minimum
- flag a WARN when the baseline is more conservative than readiness, because the system may be leaving internal capacity unused

## Why this matters
These three layers answer different questions:
- readiness asks “can the package and beat plan support the shot?”
- routing comparison asks “what should the baseline execution mode be for this location?”
- zone/practical stress asks “does lighting complexity force the route upward anyway?”

If they disagree, engineering needs to know whether that is intentional or a gap in the engine design.
