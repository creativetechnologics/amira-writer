# 88 — Beat Lighting Readiness Scoring

Date: 2026-03-31

## Purpose
Score whether a beat-level lighting plan is strong enough for internal, hybrid, or fallback routing.

## Inputs
A beat-lighting readiness fixture should combine:
- beat-lighting plan data
- package readiness per participating character
- character-to-protection-channel mapping
- revision sensitivity
- character count
- lighting profile / location context

## Scoring dimensions
- **continuity** — shared light world and continuity-note preservation
- **protection** — protection-channel coverage on dialogue/singing beats
- **focus coverage** — the currently featured character(s) have the correct protection channels on the relevant beat
- **practical discipline** — practicals remain subordinate to the world key
- **package support** — the participating characters are at least dialogue/performance ready
- **revision suitability** — internal route favored when revision sensitivity is high and continuity is strong

## Suggested result fields
- `continuityScore`
- `protectionScore`
- `practicalScore`
- `focusCharacterScore`
- `packageScore`
- `packageFloor`
- `weightedScore`
- `readinessTier`
- `recommendedRouting`
- `perCharacterFocusCoverage`
- `blockingIssues`
- `warnings`

## Routing rule
- strong continuity + strong protection + performance-ready packages -> internal
- mixed scores or lighting-complex locations -> hybrid
- broken continuity or weak package support -> ai-video-fallback or manual

## Required blocking rules
- missing `sharedLightWorld` is a BLOCK
- any beat missing the protection channel for the focused character is a BLOCK
- any practical that hijacks `ch01_world_key` is a BLOCK
- a participating character below dialogue-ready can prevent internal routing

## Engine-level rule
The readiness contract must stay character-agnostic. Luke/Amira fixtures are only test coverage. Production inputs should always provide `characterProtectChannels` explicitly so the same scorer works for any cast combination.
