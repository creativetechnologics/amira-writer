# 103 — Lighting Engine Integration Ladder

Date: 2026-03-31

## Purpose
Define the order in which the future real app should absorb the lighting-engine sandbox work.

## Integration order
1. **Read-only fixture loading**
   - profiles
   - response metadata
   - shot lighting plans

2. **Research-only lighting adapter**
   - no production UI dependency
   - no destructive migration
   - feature-flagged path only

3. **Pilot acceptance wiring**
   - acceptance matrix
   - lighting review results
   - package/readiness checks

4. **Routing handshake**
   - readiness
   - routing baseline
   - stress cross-check
   - consistency reporting

5. **Ensemble expansion**
   - support-protection channels
   - stress-aware routing floors
   - ensemble diff/report bundles

6. **Production hardening**
   - automated handoff-output rebuilds
   - regression checks in validation/test loops

## Out-of-order anti-patterns
Do not:
- start with special-case scene tuning
- wire lighting directly into production export first
- skip acceptance outputs
- skip regression/diff reporting

## Handoff rule
Every integration milestone should point back to:
- docs
- example fixtures
- validator tools
- generated handoff outputs
