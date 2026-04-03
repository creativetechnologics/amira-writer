# 107 — Combined Engine Integration Program

Date: 2026-03-31

## Purpose
Turn the combined rollout matrix into a concrete future implementation program for the full animation engine.

## Program order
1. **Shared contracts first**
   - package
   - motion
   - mouth
   - lighting
   - acceptance / diff outputs

2. **One deterministic hero pilot**
   - one character
   - one costume
   - one location
   - internal route only

3. **Singing + readability expansion**
   - mouth timing
   - face/mouth survivability
   - stable relight under dialogue/singing

4. **Routing-aware execution**
   - readiness
   - baseline route comparisons
   - stress minima
   - cross-check reporting

5. **Controlled ensemble scaling**
   - multi-character blocking
   - ensemble mouth coverage
   - ensemble lighting stress/diff governance

6. **Production hardening**
   - regression outputs
   - handoff audits
   - upgrade policies
   - acceptance-gated rollout

## Anti-patterns
Do not:
- overbuild one subsystem far ahead of the others
- start with special-case scene hacks
- skip generated outputs and rely on prose only
- wire broad production UI before adapters and acceptance gates exist

## Handoff rule
Every combined-band implementation step should map back to:
- docs
- fixtures
- validators
- generated handoff outputs
