# 67 — Weather, Practical, and Camera Lighting Rules

Date: 2026-03-31

## Purpose
Extend script-to-lighting translation so it reacts to more than just time of day.

## Weather modifiers
- dust / sand -> lower contrast, increase haze, reduce saturation
- smoke / fog -> increase depth separation haze, compress highlights
- rain -> cool the palette, soften contrast, allow wet practical accents if supported

## Practical-light modifiers
- fluorescent -> cooler fill, flatter shadow transitions
- tungsten -> warmer key/fill, stronger contrast in interiors
- fire / candle -> warm flicker, unstable rim, protect face readability aggressively
- mixed practicals -> prefer hybrid routing if the engine cannot maintain coherence

## Camera modifiers
- close-up / medium close-up -> always prefer face protection
- wide shot -> reduce face protection priority, emphasize zone coherence
- profile-heavy staging -> increase rim usefulness if silhouette is at risk
- singing close-up -> face protection + mouth visibility protection both mandatory

## Translation principle
The translator should choose one base profile, then apply weather, practical, and camera modifiers in a deterministic order.
