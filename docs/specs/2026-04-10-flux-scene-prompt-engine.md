# FLUX Scene Prompt Engine — Multi-Character LoRA Notes

Date: 2026-04-10  
Workspace: `/Volumes/Programming/Amira Writer`

## Problem

Scene prompts were too freeform for FLUX + Draw Things multi-character generations:

- subject identity words were not strongly bound to the right character action
- random trigger tokens for newer character LoRAs were not anchored beside the matching name
- prompts buried blocking/composition under atmosphere prose
- the scene picker still defaulted to older model assumptions

## New Prompt Strategy

For FLUX.2 [klein], front-load in this order:

1. **Named character blocking**
   - `Luke on screen-left ... Matt on screen-right ...`
2. **Visible action**
   - one distinct clause per character
3. **Camera / composition**
   - shot size, eye-level / low-angle, lens feel
4. **Setting / light**
   - location, time of day, atmosphere, key props
5. **Guardrails**
   - photoreal, no text, no watermark, not anime, not illustration

Target range:

- **45–95 words**
- **2–4 short sentences**
- natural language, not keyword soup

## LoRA Binding Rule

For multi-character prompts, random trigger words must sit **inline next to the matching character mention**, not merely dumped at the very front of the prompt.

Good:

- `Matt mttq39 on screen-right...`

Weak:

- `mttq39, Luke and Matt in a street scene...`

If the trigger word is already the visible name token (for example `luke`), no extra duplication is needed.

## Draw Things Notes

Draw Things currently:

- supports **FLUX.2 [klein]** models and importing LoRAs for them
- supports **Bring Your Own LoRA** on Cloud Compute
- allows custom default LoRA weight ranges via `custom_loras.json`

That means Draw Things is still a viable scene-iteration tool, but **pure txt2img is the wrong place to demand exact blocking precision**. Once composition matters, switch to one of:

1. txt2img for discovery
2. pick the best composition
3. img2img / edit from that composition for continuity

## Recommended Manual Prompt Shape

Use:

`[names + blocking + action]. [camera sentence]. [setting/light sentence]. [guardrail sentence].`

Example shell:

`Luke on screen-left faces Matt on screen-right as Matt crouches beside the clinic doorway and Luke pauses mid-step in the dusty street. Medium-wide eye-level handheld documentary frame, 35mm lens feel, both faces readable, Luke foreground-left and Matt midground-right. Pre-dawn clinic exterior, plaster walls, corrugated awning, weak doorway light, suspended dust, restrained humanitarian checkpoint realism. Photoreal cinema still, natural skin texture, grounded wardrobe, no text, no watermark, not anime, not illustration.`

## Luke + Matt Prompt Trials

### Trial A — safest blocking test

Use Luke’s current trigger if needed; Matt’s latest recorded trigger is `mttq39`.

`Luke on screen-left faces Matt mttq39 on screen-right as Matt crouches beside the clinic doorway and Luke pauses mid-step in the street. Medium-wide eye-level documentary frame, 35mm lens feel, both faces fully readable, Luke foreground-left and Matt midground-right. Pre-dawn district clinic exterior with plaster walls, corrugated awning, weak doorway light, drifting dust, grounded early-2000s Afghanistan realism. Photoreal cinema still, natural skin texture, no text, no watermark, not anime, not illustration.`

### Trial B — stronger action separation

`Luke on screen-left turns toward Matt mttq39 on screen-right while Matt kneels to inspect something at the clinic threshold and keeps his gaze down. Medium shot at eye level, restrained handheld realism, shallow depth of field but both faces still legible, Luke left foreground and Matt right midground. Dusty clinic exterior at first light, concrete and mud-brick surfaces, practical doorway lamp, muted military and civilian textures. Photoreal documentary still, grounded wardrobe, no text, no watermark, not anime, not illustration.`

### Trial C — profile / facing stress test

`Luke on screen-left in three-quarter profile facing screen-right watches Matt mttq39 on screen-right in three-quarter profile facing screen-left as Matt rises from a crouch near the doorway. Medium-wide locked frame, eye-level 40mm lens feel, both bodies visible from knee-up, clean left-right separation. Pre-dawn clinic street with plaster walls, corrugated shade, soft cold dawn light and one warm doorway practical. Photoreal cinema still, realistic anatomy and skin, no text, no watermark, not anime, not illustration.`

## Weighting Suggestions For Duo Scenes

Start here:

- primary character scene: **1.0 + 0.8**
- balanced duo scene: **0.85 + 0.85**
- if faces start blending: **0.75 + 0.75** and simplify the prompt

Do not try to solve identity drift only by raising weights. Usually fix these first:

1. bind each trigger inline to the right name
2. shorten the prompt
3. give each character only one action
4. keep left/right explicit

## Place / Scenery / Style LoRAs

Yes — this is viable, but treat it as a **separate environment/style LoRA track**, not part of character identity.

Recommended split:

- **Character LoRAs** = face/body identity
- **Environment/style LoRAs** = clinic street mood, plaster/mud-brick textures, documentary grade, dawn palette

Best use cases:

- recurring clinic exterior look
- consistent dusty street palette
- specific documentary grade / lens texture / production design feel

Less ideal use cases:

- exact scene blocking
- exact prop placement
- exact left/right staging

Those remain better handled by composition references or edit workflows.
