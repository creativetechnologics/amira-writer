# 36 — Readiness-to-Routing Bridge

Date: 2026-03-31

## Purpose
Connect package readiness levels to routing defaults so shot planning reacts to package maturity.

## Readiness states
- draft
- blocking-ready
- dialogue-ready
- performance-ready
- production-ready

## Default routing bias by readiness
### Draft
- avoid internal unless the shot is trivial and temporary
- prefer manual blocking only

### Blocking-ready
- internal for static/blocking shots only
- not enough for hero dialogue or singing closeups

### Dialogue-ready
- internal for closeups and restrained dialogue
- hybrid for moderate complexity
- avoid ai-video unless spectacle demands it

### Performance-ready
- internal for most dialogue, singing medium shots, and controlled locomotion
- hybrid for more complex environmental or overlay pressure

### Production-ready
- internal by default for any shot within the package envelope
- hybrid only when one complexity axis spikes
- ai-video fallback only for clearly out-of-envelope spectacle

## Bridge logic
Routing should consider both:
- readiness state
- shot complexity

High readiness lowers the threshold for choosing internal.
Low readiness raises it.

## Recommendation
Implement this as a small scoring bridge, not a giant rules matrix.
