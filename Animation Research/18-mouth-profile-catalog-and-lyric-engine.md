# 18 — Mouth Profile Catalog and Lyric Engine Plan

Date: 2026-03-31

## Purpose
Define a practical, anime-caliber mouth system that can sit on top of the general animation engine.

## Core decision
The mouth engine should stay separate from the body engine.

Why:
- body motion is sparse-keyframe and pose-driven
- mouth motion is dense and timing-driven
- singing needs different timing and sustain rules than speech
- mouth placement depends on angle, crop, and local face geometry

## Recommended mouth profile structure
A mouth profile should be defined per angle family, not per individual drawing.

Recommended angle families:
- front
- quarter-left
- quarter-right
- profile-left
- profile-right
- optional back / obscured fallback

Each profile should include:
- mouth anchor position relative to the head asset
- anchor width / height reference
- neutral/rest mouth
- speech viseme set
- singing extensions
- transition hints
- occlusion rules
- fallback mappings for missing shapes

## Recommended viseme inventory

### Minimum speech set
Use the Preston Blair / Rhubarb core as the base layer:
- rest / idle
- MBP closed
- consonant / clenched (etc)
- E / EH
- AI / wide open
- O / rounded
- U / puckered

### Recommended extended speech set
Add if the character is important:
- FV
- L
- smile-closed
- smile-open
- tense-open

### Recommended singing extensions
For heroes and strong supporting singers:
- belt-wide
- belt-round
- sustained-open-medium
- sustained-open-wide
- whisper-soft
- cry / strain
- vibrato-open-small

## Mapping guidance
Rhubarb documents the classic 6 basic mouth shapes plus optional G/H/X extensions, and Adobe Animate exposes 12 basic visemes. The most practical plan for this project is:
- store a compact runtime viseme family
- allow richer authoring aliases
- map multiple phoneme classes into the same visual family

Recommended canonical runtime families:
- rest
- mbp
- ee_tight
- eh_mid
- aa_wide
- oh_round
- oo_pucker
- fv
- l_tongue
- smile
- belt
- strain

## Speech timing rules
- prefer stable held shapes over hyperactive swapping
- lead consonant closures slightly before the audio peak
- hold vowels slightly longer than consonants
- allow smoothing/in-betweens between open families
- preserve readability over literal phonetic accuracy

## Singing timing rules
- vowels dominate
- sustained notes should hold vowel families, not chatter through consonants
- consonants should be short accents unless lyrical intelligibility demands otherwise
- phrase starts and ends need softer attack/release than speech
- emotional singing should bias shape choice (smile, strain, cry, belt) more than strict phoneme logic

## Suggested lyric pipeline
1. source text / lyrics
2. optional aligned audio or syllable timing
3. phoneme or vowel-class pass
4. collapse to canonical viseme families
5. apply singing timing rules
6. resolve angle family
7. emit mouth plan + overlay timeline

## Placement and angle rules
The mouth engine should not guess placement every frame from scratch.
Each mouth profile should provide:
- mouth anchor center
- width scale
- rotation / skew hint
- visibility rules
- profile-side occlusion expectation

For example:
- front: symmetric placement
- quarter-left: shift right on the canvas, compress far corner
- profile-left: narrow width, visible outer lip line, limited inner-mouth detail

## AI assistance opportunities
Gemini image understanding can help with:
- bounding boxes for mouth area
- rough segmentation of face regions
- detecting whether the mouth is too high/low/wide after generation

Gemini structured output can then return a machine-readable QA report for mouth assets.

## Asset counts implied by this plan
### Hero singer
Per costume-neutral head family:
- 5 primary angle families
- 10–16 shapes each depending on richness
- practical total: **50–80 mouth assets**

### Supporting speaking role
- 3–5 angle families
- 7–10 shapes each
- practical total: **21–50 mouth assets**

Most costumes should reuse the same mouth package unless scarves, veils, masks, or heavy makeup materially change visibility.

## Recommended implementation order later
1. front mouth profile
2. quarter-left / quarter-right profiles
3. singing timing layer
4. profile-left / profile-right profiles
5. QA and correction automation

## Planning takeaway
Anime-caliber results do not require frame-by-frame hand animation, but they do require:
- angle-aware mouth assets
- stable mouth anchors
- speech vs singing timing separation
- explicit fallback rules
