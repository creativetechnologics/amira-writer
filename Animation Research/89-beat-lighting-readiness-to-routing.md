# 89 — Beat Lighting Readiness To Routing

Date: 2026-03-31

## Purpose
Bridge beat-lighting readiness results directly into routing expectations.

## Rule of thumb
- `internal` when the beat-lighting plan is stable and both characters are ready enough for continuity-heavy retakes
- `hybrid` when the beat-lighting plan is good but practical complexity or night readability make assisted polish worthwhile
- `ai-video-fallback` when the beat-lighting plan itself is unstable or character package readiness is too low

## Key override rule
A location like `village-street-night` may still prefer `hybrid` even with a strong beat-lighting score because low-value practical interaction is inherently fragile.

## Minimum bridge inputs
- readiness report with:
  - `continuityScore`
  - `protectionScore`
  - `focusCharacterScore`
  - `packageScore`
  - `packageFloor`
  - `readinessTier`
- location ID
- revision sensitivity

## Expected bridge behavior
- `fallback-only` readiness tier always maps to `ai-video-fallback`
- `internal-ready` can still downgrade to `hybrid` for fragile night-practical locations
- a low `packageFloor` should block `internal` even when the average package score is high

## Engine-level rule
The bridge should never depend on specific hero names or scene IDs. Character-specific fixtures are examples only; the routing bridge should consume generic participant metadata and explicit protection-channel mappings.
