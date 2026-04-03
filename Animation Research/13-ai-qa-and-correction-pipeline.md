# 13 — AI-Assisted QA and Correction Pipeline for Character Assets

Date: 2026-03-31

## Purpose

This document defines a practical QA-and-correction loop for character assets generated with Gemini / Nano Banana-style image models. The goal is to let AI do two jobs safely:

1. Review generated assets against the approved character spec
2. Produce targeted edit instructions when the asset is close but not correct

The output is not just a pass/fail check. It is a structured review artifact that can drive a second-generation edit pass, a narrow correction pass, or a full regeneration decision.

---

## Why this needs to be its own subsystem

Character generation is not the same problem as character approval.

A generation system wants to make a plausible image.
A QA system wants to answer:

- Is this the same character?
- Is the angle correct?
- Is the costume correct?
- Is the body readable at animation scale?
- Can we repair it cheaply, or should we regenerate?

Those are different tasks, and the model should be asked to do them in a different mode.

For this project, the best pattern is:

1. Generate a candidate asset
2. Review it against the reference package
3. Classify the problems by severity
4. Repair via a targeted edit prompt if the issue is local
5. Regenerate if the issue is structural
6. Approve only after the asset passes the review schema

---

## Official Google capabilities that make this feasible

### 1) Gemini can review images directly
Google’s Gemini image understanding docs confirm that Gemini models are multimodal and can accept images for tasks like classification, object detection, segmentation, and general visual question answering. That is enough to use the model as a first-pass asset reviewer.

Source:
- https://ai.google.dev/gemini-api/docs/vision

### 2) Gemini supports structured outputs
Google’s structured output docs show that Gemini can emit JSON matching a provided schema, using `response_mime_type: application/json` and a JSON Schema definition. That is the key to making the QA pass machine-readable.

Source:
- https://ai.google.dev/gemini-api/docs/structured-output

### 3) Files can be reused across many review requests
Google’s Files API docs show that uploaded media can be reused across multiple prompts. That matters because the same character references will be reviewed over and over.

Source:
- https://ai.google.dev/api/files

### 4) Gemini’s image generation stack supports image editing workflows
Google’s image-generation docs describe multimodal image prompting and editing workflows that can combine reference images and text instructions. That makes the correction stage practical once the QA review identifies a fix.

Source:
- https://ai.google.dev/gemini-api/docs/image-generation

---

## Recommended QA workflow

### Step A — Assemble the review packet
For each generated asset, provide:

- the generated image itself
- the approved master sheet or sheet subset
- the correct costume reference sheet
- the correct head-turnaround or body-turnaround sheet
- optional angle-specific mouth / accessory references
- the character spec record

### Step B — Ask Gemini to review only against the approved spec
The model should not be allowed to invent a new character interpretation.
It should be asked to compare the generated asset against the reference set and return a structured review record.

### Step C — Force a JSON review result
The review result should include:

- pass/fail status
- confidence score
- issue list with severities
- what is wrong
- which reference it violated
- whether the asset can be edited or must be regenerated
- a short correction prompt

### Step D — Choose the correction strategy
Use the review result to decide:

- approve — asset is good enough
- edit — small local fix is possible
- regenerate — the structure is wrong, do not patch it
- reject — the asset is beyond salvage
- escalate — send to human review because the model is uncertain

---

## What the QA model should check

### 1) Identity
Does the character still look like the same person?

Check:
- face shape
- age presentation
- skin tone
- hairline
- beard / eyebrows / major facial landmarks
- body shape and proportions
- silhouette consistency

### 2) Angle correctness
Is the requested angle actually present?

Check:
- front vs quarter vs profile vs back
- orientation of shoulders and torso
- head and body direction consistency
- whether mirrored directions are accidentally swapped

### 3) Costume correctness
Is the approved costume preserved?

Check:
- garment type
- pocket placement
- collar / scarf / straps
- civilian vs soldier wardrobe distinction
- era-appropriate fabric and gear
- accidental costume drift

### 4) Animation usefulness
Can this asset be used in the runtime?

Check:
- silhouette readability
- clean edges
- part separation potential
- missing limbs or occluded joints
- whether the image is too busy for keyframe-driven reuse

### 5) Composition / crop correctness
Does the asset fit the intended sheet or pose slot?

Check:
- framed correctly for the requested slot
- not clipped unless clipping is expected
- centered appropriately
- enough space for rig extraction

### 6) Technical cleanliness
Can the asset survive downstream processing?

Check:
- no broken anatomy
- no extra fingers
- no duplicated limbs
- no strange merged accessories
- no text/watermark artifacts
- no background junk that should not be there

---

## Severity model

A practical QA pass should classify issues like this:

### Critical
The asset cannot be used without full regeneration.
Examples:
- wrong character identity
- wrong costume family
- completely wrong angle
- broken anatomy that affects the whole pose
- missing major body parts

### Major
The asset might be fixable, but only with a serious edit.
Examples:
- pocket placement wrong
- scarf shape wrong
- shoulder geometry inconsistent
- profile direction is close but incorrect
- head expression off-model

### Minor
The asset is usable but could be improved.
Examples:
- small style drift
- tiny costume detail mismatch
- slightly awkward hand pose
- weak line cleanup

### Informational
A note, not a blocker.
Examples:
- lighting differs slightly
- background is more detailed than ideal
- asset is slightly less clean than the best variant

---

## What counts as a correct asset

A correct asset is not just "pretty." For this project, a correct asset is one that is:

- consistent with the approved reference package
- usable for the intended runtime slot
- clear enough for animation reuse
- close enough to the visual bible that downstream assets remain coherent

That means the QA pass should optimize for reuse and consistency, not only aesthetic quality.

---

## Recommended review strategy by asset type

### Master sheets
Review for:
- identity consistency across all panels
- angle correctness
- stable costume logic
- panel ordering
- matching facial landmarks
- whether it can serve as a source of truth for later generation

### Head turnarounds
Review for:
- angle correctness
- head symmetry and family consistency
- mouth and face placement
- back-of-head readability
- whether front and profile views stay clearly distinct

### Full-body pose sheets
Review for:
- stance readability
- body angle correctness
- costume continuity
- pose coverage
- silhouette stability

### Costume sheets
Review for:
- costume family correctness
- pocket/strap/collar placement
- civilian-vs-soldier distinction
- how cleanly the costume would layer over the base package

### Accessories and props
Review for:
- correct prop type
- attachment plausibility
- scale and placement
- consistency with the approved costume/scene context

---

## Correction strategy

### When to use edit mode
Use edit mode when the mistake is local and the image is otherwise strong.
Examples:
- remove two pockets
- make the scarf slimmer
- correct a sleeve
- adjust the mouth angle
- fix a slightly wrong profile direction

### When to use regenerate mode
Use regenerate when the structure is wrong.
Examples:
- wrong costume family
- wrong character identity
- wrong body angle
- wrong pose family
- wrong sheet layout

### When to use human escalation
Escalate when:
- the model is uncertain
- the image is borderline but important
- there is a subtle identity drift that matters for a main character
- the correction prompt would be too broad or risky

---

## How to make the correction loop work with Gemini/Nano Banana

The best pattern is a two-step multimodal loop:

1. Review pass
   - input: generated image + reference images + character spec
   - output: structured review JSON

2. Edit pass
   - input: original image + reference images + the review-generated correction prompt
   - output: corrected candidate image

The review pass should produce a short, direct correction prompt rather than a vague essay.
That prompt should be ready to feed into the image model immediately.

Example flow:

- Generated image comes in
- Review model says: major costume error, wrong pocket layout
- System generates edit prompt: remove the two front chest pockets, keep the rest unchanged
- Image model edits the same image
- Second review confirms whether the correction worked

---

## Human-in-the-loop guardrails

Even with a strong AI reviewer, human approval should remain the final gate for:

- main-character sheets
- canonical full-body turnarounds
- canonical head sheets
- costume bible sheets
- any asset that will be reused across many scenes

The AI reviewer should reduce labor, not eliminate final judgment.

---

## What this toolkit should eventually become in code

The future implementation should likely include:

- a structured review schema
- a review prompt template
- an edit-prompt template
- a correction ladder
- a manual approval queue
- asset-version comparison history
- good enough to use thresholds by asset type

That gives the team a safe way to use AI for quality control without turning AI into the only judge.

---

## Bottom line

Yes, Gemini/Nano Banana-style models can absolutely be used as a QA and correction layer for generated character assets.

The correct design is:

- multimodal review to judge correctness
- structured output to make the result machine-readable
- targeted edit prompts for small fixes
- full regeneration for structural mistakes
- human approval for canonical assets

That is the most practical way to turn AI image generation into a controlled character-asset production pipeline.
