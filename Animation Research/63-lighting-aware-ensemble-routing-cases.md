# 63 — Lighting-Aware Ensemble Routing Cases

Date: 2026-03-31

## Purpose
Extend routing guidance so shot complexity includes lighting complexity, not just motion and character count.

## Case 1 — Sunset trio dialogue exterior
- category: ensemble_dialogue
- characters: 3
- lighting: sunset_warm
- likely routing: hybrid
- reason: body/mouth systems are still viable, but shared face readability across three characters needs a stable lighting pass

## Case 2 — Night market walk-and-talk
- category: moving_ensemble
- characters: 2 featured + crowd
- lighting: moonlight_blue + warm practical stalls
- likely routing: hybrid or ai-video-fallback
- reason: mixed practical lighting and crowd motion increase coordination cost

## Case 3 — Clinic interior emergency scene
- category: ensemble_reactive
- characters: 4
- lighting: fluorescent_clinic
- likely routing: hybrid
- reason: flatter interior lighting helps the internal engine if the practical-light plan is stable

## Case 4 — Firelit argument close-up exchange
- category: duet_closeup
- characters: 2
- lighting: firelight_flicker
- likely routing: hybrid, potentially fallback if flicker behavior is not yet robust

## Case 5 — Dust storm checkpoint wide
- category: action_wide
- characters: 5+
- lighting: dust_storm_flat
- likely routing: ai-video-fallback
- reason: atmosphere + group motion + wide layout exceed the low-risk pilot target

## Routing principle
Lighting complexity should count as a co-equal routing factor beside:
- motion complexity
- character count
- camera intensity
- prop/environment interaction
