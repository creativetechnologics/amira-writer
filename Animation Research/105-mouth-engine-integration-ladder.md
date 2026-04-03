# 105 — Mouth Engine Integration Ladder

Date: 2026-03-31

## Purpose
Define the order in which the future app should absorb the mouth-engine sandbox work.

## Integration order
1. **Read-only profile and preset loading**
   - mouth profiles
   - angle families
   - speech/singing presets

2. **Research-only mouth adapter**
   - feature-flagged
   - additive only
   - no destructive migration

3. **Speech pilot wiring**
   - one-character speech playback
   - anchor validation
   - mouth-layer switching

4. **Singing pilot wiring**
   - lyric timing
   - sustain rules
   - phrase attack/release rules

5. **Lighting and readability handshake**
   - mouth survivability under active lighting
   - protection-lane cooperation

6. **Production hardening**
   - diff/regression checks
   - acceptance matrix enforcement
   - handoff bundle automation

## Anti-patterns
Do not:
- treat mouth as a tiny sub-feature of body animation
- skip angle families
- skip singing-specific timing
- wire directly into full-scene runtime before fixture validation

## Handoff rule
Each integration step should map back to:
- docs
- example fixtures
- validator tools
- generated outputs
