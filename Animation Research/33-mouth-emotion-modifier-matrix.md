# 33 — Mouth Emotion Modifier Matrix

Date: 2026-03-31

## Purpose
Define how emotion should modify otherwise neutral speech/singing mouth behavior.

## Why
A technically correct vowel shape can still feel emotionally dead.
The mouth engine needs a second layer that says how the mouth should behave for the current emotional state.

## Modifier dimensions
- openness bias
- corner tension
- roundness bias
- release softness
- sustain stability
- asymmetry tolerance

## Emotion examples
### Calm
- low openness bias
- soft release
- low asymmetry

### Concerned
- medium tension
- slightly reduced smile tendency
- moderate release softness

### Sad
- softer lower-lip weighting
- slower attack and release
- occasional downward corner bias

### Angry
- higher tension
- sharper attack
- reduced softness
- strain variants more acceptable

### Heroic / resolute singing
- wider stable vowels
- strong attack
- clean sustained openness
- limited chatter

### Crying / breaking voice
- strain bias
- imperfect release
- occasional asymmetry if style allows

## Recommendation
Store emotion modifiers as lightweight overlays on top of the canonical viseme family, not as a full second mouth library whenever possible.
