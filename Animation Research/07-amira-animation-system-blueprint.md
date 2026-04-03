# 07 — Amira Animation System Blueprint

Date: 2026-03-30

## Purpose
This document synthesizes the research in this folder into one concrete future architecture for **Amira Writer's semi-autonomous 2D animation system**.

The system goal is:

> Start with script-level intent, use structured character packages plus motion planning to animate most shots internally, and reserve AI video for the minority of shots that are too fluid, too complex, or too expensive to rig by hand.

---

## 1. Final recommendation in one sentence

Amira Writer should evolve into a **layered animation stack**:

1. **Character Package System** — reusable, approved assets and metadata
2. **Body Motion Engine** — blocking, locomotion, acting, and pose interpolation
3. **Mouth Engine** — angle-aware speech/singing lip sync on top of the body engine
4. **Overlay Systems** — blinks, gaze, breathing, props, cloth, and minor corrections
5. **Shot Router** — decides whether a shot stays internal or gets external AI-video assistance
6. **QA + Approval Layer** — keeps everything deterministic, reviewable, and replaceable

---

## 2. Why this architecture is the right one

The research converges on the same pattern from multiple directions:

- **Spine / game-style runtimes** say runtime playback should be data-oriented: skeleton, slots, skins, attachments, animations.
- **Toon Boom Harmony / cut-out workflows** say a production rig needs organized reusable parts, deformer/peg hierarchy, and controlled drawing substitutions.
- **Live2D** says face and upper-body nuance benefit from parameterized layers and careful separation of control spaces.
- **Adobe Character Animator / lip-sync systems** say mouth shapes are their own asset family and should be mapped by visemes.
- **Modern motion research** says sparse anchors + infill are a better abstraction than trying to generate every frame directly.
- **Current AI image/video tooling** says reference images, sheets, and controlled prompts are strong, but fully deterministic long-form video continuity is still weaker than an internal shot engine.

So the best long-term strategy is not “animate everything with video.”
And it is not “build a microscopic puppet for every possible motion.”
It is a hybrid: **structured reusable packages + sparse motion plans + overlays + targeted AI fallback**.

---

## 3. The major subsystems

### 3.1 Character Package System
This is the durable visual truth for each character.

It should store:
- identity references
- approved master sheets
- approved head sheets
- costume sheets
- body rig pieces
- face/expression assets
- mouth/viseme assets
- gesture and hand assets
- accessories and props
- metadata about placement, pivots, compatibility, and quality status

Key principle:
**The package is not just art storage. It is the runtime contract.**

### 3.2 Body Motion Engine
This system owns:
- staging
- blocking
- locomotion
- weight shifts
- reaches
- turns
- seated / kneeling / practical acting
- camera-relative placement
- interpolation between sparse motion anchors

It should operate on:
- motion primitives
- sparse keyframes
- attachment points
- angle-aware asset selection
- per-shot overlay hooks

Key principle:
**The LLM writes the plan; the runtime performs the plan.**

### 3.3 Mouth Engine
This should be a separate subsystem with its own data and logic.

It owns:
- speech viseme timing
- singing viseme timing
- mouth registration points
- mouth angle selection
- vowel holds
- consonant compression
- mouth intensity and openness curves
- fallback behavior when an exact angle asset is missing

Key principle:
**The mouth engine overlays the body engine; it does not replace it.**

### 3.4 Overlay Systems
These are lightweight systems that sit on top of base body motion:
- blinks
- eye gaze
- eyebrow emphasis
- breathing
- hair follow-through
- cloth follow-through
- prop offsets
- dust / atmospheric sprite overlays if needed

Key principle:
**Overlays should be independent enough to revise without re-authoring the base shot.**

### 3.5 Shot Router
This decides whether a shot is:
- internal-only
- internal + overlays
- internal + mouth engine
- internal + AI-video assist
- AI-video-first with internal prep frames

Key principle:
**AI video is a routing choice, not the default runtime.**

---

## 4. The package hierarchy we should build toward

### Level A — Identity Layer
- canonical face photo(s)
- canonical full-body reference(s)
- approved master sheet
- style anchors
- costume bible
- palette references

### Level B — Sheet Layer
- head turnaround sheet
- full-body turnaround sheet per costume
- accessory/prop sheets
- hand/gesture sheets
- expression sheet
- mouth/viseme sheet per head angle family

### Level C — Rig Layer
- torso
- hips
- neck
- head shell
- hair front/back
- brows
- eye whites/pupils/lids
- jaw / lower face (optional by style)
- upper/lower arms
- hands
- upper/lower legs
- feet
- costume overlays
- accessory overlays

### Level D — Performance Layer
- walk starts / loops / stops
- turns
- idle variants
- reaches
- reactive poses
- seated / kneeling / crouching bases
- hero gestures
- hand pose families

### Level E — Overlay Layer
- mouth profiles
- blink sets
- gaze rules
- breathing curves
- prop offsets

---

## 5. What the LLM should actually output

Not frame-by-frame animation.

The LLM should output:
- shot intent
- motion primitive selection
- sparse keyframe anchors
- character coordinates
- facing direction
- camera relation
- emotional intensity
- prop state
- overlay requirements
- confidence / fallback suggestions

The runtime then turns that into:
- pose selections
- interpolation curves
- attachment swaps
- mouth timelines
- blink/gaze overlays
- optional AI-video handoff inputs

---

## 6. The separate mouth engine design

The research strongly supports your instinct:
this should be a separate engine.

### Why
Because mouth motion has different requirements from body motion:
- it is audio/text aligned
- it is more angle-sensitive
- it needs faster swap timing
- it often wants different smoothing rules
- singing and speech are different behaviors

### Mouth engine input
- dialogue text or lyrics
- optional audio / alignment data
- shot fps
- active character
- head angle / head-family identifier
- emotional intensity

### Mouth engine output
- viseme keyframes
- openness curve
- optional jaw curve
- angle-specific mouth asset selections
- placement corrections
- warnings when exact angle assets are missing

### Mouth engine fallback ladder
1. exact angle mouth assets
2. nearest compatible angle family
3. simple rest/open/closed fallback
4. external assist generation for missing mouth banks

---

## 7. Internal shot categories

### Best internal-engine shots
- close dialogue
- medium dialogue
- held singing shots
- walking across frame
- seated scenes
- controlled emotional acting
- repeated background business
- most TV/anime-style coverage

### Best AI-video-assist shots
- crowds
- chaotic action
- heavy atmospheric motion
- complex cloth / smoke / debris
- difficult moving camera shots
- shots where continuity can be preserved with strong start/end frames

---

## 8. Recommended asset completeness tiers

### Tier 1 — MVP internal animation package
Enough to animate basic scenes:
- master sheet
- head sheet
- one costume full-body sheet
- basic expressions
- basic viseme bank
- walk / idle / turn / reach primitives

### Tier 2 — Production conversation package
Enough for most dramatic scenes:
- 2 costume packs
- extended expression family
- hand sets
- seated / kneeling / react poses
- angle-aware mouth banks
- prop overlays

### Tier 3 — Feature-grade hero package
Enough for lead-character coverage:
- multi-costume body sheets
- hero gesture banks
- corrective angle overlays
- stronger gaze / blink / brow layers
- special singing mouth profiles
- shot-specific augmentation assets

---

## 9. What should happen next

### Immediate research-to-build priorities
1. lock the package spec
2. lock the mouth engine spec
3. lock the motion-plan JSON contract
4. build one full Luke hero package to the new standard
5. validate on a few canonical shots
6. only then generalize to the rest of the cast

### Best proving-ground sequence
1. Luke
2. Amira
3. one supporting soldier
4. one civilian

This will reveal which parts of the spec are universal and which are overbuilt.

---

## 10. Final recommendation

The internal animation system should be the main engine.
The mouth engine should be separate.
The character package should be much richer than the current proof-of-concept.
AI image generation should feed the package factory.
AI video should be routed in only when the internal system is a bad fit.

That is the architecture most likely to actually finish a feature film while remaining editable, reusable, and economically sane.
