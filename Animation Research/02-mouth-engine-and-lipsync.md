# Mouth Engine and Lip Sync Research

Date: 2026-03-30

## Goal
Define how a separate mouth-movement engine should work for semi-autonomous 2D animation in Amira Writer: strong enough for anime-caliber lip sync and singing, but still lightweight, editable, and compatible with the existing character-package system.

---

## Executive summary

The research points to a clear design direction:

1. **Treat mouth animation as its own engine**, not as a minor detail inside the general animation system.
2. **Use visemes, not raw phonemes, as the runtime animation unit.**
3. **Separate singing from speech**, because singing needs longer holds, more vowel emphasis, and smoother co-articulation.
4. **Make mouth assets angle-aware** so the engine can pick the correct mouth view for front, quarter, and profile heads.
5. **Prefer a hybrid system**:
   - deterministic mouth timing and curve generation from text/audio
   - artist-editable overrides
   - optional AI assistance for missing mouth variants or difficult scenes

The important practical conclusion is that a feature-grade package needs more than a small handful of “mouth shapes.” It needs a **canonical mouth set**, **angle variants**, **registration data**, **transition logic**, and **fallback behavior** when the exact asset is missing.

---

## What the external references say

### 1) Visemes are the right runtime unit, not phonemes

Adobe Character Animator explicitly says visemes are the visual equivalent of phonemes, but the correspondence is **not one-to-one**. Its lip-sync docs also note that audio-based visemes are the main runtime input, while neutral/smile/surprised can come from webcam-driven shapes. That is a good reminder that a mouth system should be built around **visual categories**, not raw phonetic perfection.

Toon Boom Harmony makes the same point in a different way: its automatic lip-sync feature maps detected phonemes to a standard mouth chart, then fills the mouth layer exposures with the corresponding mouth-shape letter. Harmony does **not** invent new drawings at runtime; it expects the mouth drawings to already exist and be named or mapped properly.

**Implication:** the engine should generate a stable **viseme timeline**, then choose the best mouth drawings for the current head angle and style.

### 2) A small, standard mouth chart is normal

Toon Boom’s standard mouth chart uses letters **A, B, C, D, E, F, G, X**, and describes them as approximate phoneme groupings. Rhubarb Lip Sync uses six basic mouth shapes plus optional extended shapes, and can export to Preston Blair names.

The current Animate code already uses a Preston Blair-style viseme enum:

- rest
- A/I
- E
- O
- U
- consonant
- F/V
- L
- M/B/P
- W/Q

That is a strong default for anime-style 2D animation. It is small enough to manage, but broad enough to cover most dialogue.

**Implication:** don’t explode the core mouth set into dozens of shapes unless the project proves it needs them. Start with a compact canonical set and add specialist variants only when they solve a concrete problem.

### 3) Singing needs more than ordinary speech lip sync

The research on dynamic visemes and visual speech synthesis says that:

- phoneme context matters
- viseme context matters
- co-articulation matters
- dynamic viseme sequences outperform naive phoneme-driven systems
- natural lip motion should be smooth, but not under-articulated

That is especially relevant for singing. Singing is not just “speech with longer vowels.” It needs:

- vowel holds
- legato transitions
- less aggressive consonant snapping
- note-aware mouth openness
- phrase-level breath/rest behavior

**Implication:** the mouth engine should not treat singing as the same pipeline as fast speech. It should have its own timing profile, even if it reuses the same viseme vocabulary.

### 4) Animator-centric models are better than rigid automated ones

JALI and VisemeNet are useful because they are explicitly designed to be **animator-centric** rather than purely speech-science-centric. The research emphasizes:

- expressive lip sync that remains editable
- separate control of jaw and lip motion
- speech styles like mumbling and shouting
- curve-based outputs that can be refined by artists

This is the right philosophy for Amira Writer. The system should output **good animation curves and mouth selections**, but still let an artist override timing, intensity, and specific mouth frames.

**Implication:** the mouth engine should output a **control layer**, not a black box.

### 5) Mouth rigs must be prepared for angled views

Adobe Character Animator’s mouth-shape docs say quarter and profile views can follow the same general guidelines as frontal views, and Adobe Animate’s lip sync docs emphasize that the mouth poses live inside a single graphic symbol with named viseme frames.

That matters because our project is not a flat talking-head toy. Characters will be seen from front, quarter, and profile angles, so the engine needs:

- view-specific mouth sheets or view-specific mouth placements
- consistent registration points
- a way to choose the right mouth asset for the current head angle

**Implication:** mouth animation cannot be one flat “front mouth sheet” if the show wants consistent side-angle coverage.

---

## What the current code already does

The current Animate implementation already hints at the right architecture:

- `LipSyncEngine`
  - generates viseme keyframes from OWP lyric alignment for singing
  - generates viseme keyframes from timed phonemes for speech
- `RhubarbLipSync`
  - wraps the Rhubarb CLI
  - produces timed mouth cues from audio
- `PrestonBlairViseme`
  - gives us a compact canonical mouth vocabulary
- `TimelineTrackRole.mouth`
  - treats mouth as a first-class timeline track
- `CharacterRenderSelectionContext.mouthCue`
  - allows the renderer to select a mouth asset based on a mouth cue
- `AnimationAssetRequestPlanner`
  - already detects missing viseme coverage and can request more assets

So the codebase is already halfway to the right abstraction:

1. **timeline** knows about mouth
2. **selection context** knows about mouth cues
3. **asset planning** knows when mouth coverage is missing
4. **lip-sync engine** converts source timing into visemes

What is still missing is a stronger package format and a dedicated mouth-engine layer that treats mouth assets as a complete subsystem.

---

## What a feature-grade mouth system actually needs

The earlier “few mouth parts” assumption is too small for this project if we want semi-autonomous feature-length output.

### Minimum practical mouth package

For each character, I would expect:

- **Canonical viseme set**
  - rest
  - MBP
  - AI
  - E
  - O
  - U
  - FV
  - L
  - consonant / mid-open
  - W/Q
- **Expression overlays**
  - smile
  - frown
  - tense
  - yelling / projected singing
- **Angle variants**
  - front
  - quarter left
  - quarter right
  - side left
  - side right
- **Registration metadata**
  - where the mouth sits relative to the head in each angle
  - scale and baseline anchor
  - jaw pivot / lip anchor points
- **Transition frames**
  - closed-to-open
  - open-to-closed
  - consonant snap
  - vowel hold
- **Fallback assets**
  - if a precise angle/viseme is missing, use the nearest usable variant

### Better-than-minimum package

For a show like this, the package should also include:

- breathing / idle mouth
- speaking emphasis variants
- singing open vowels
- whisper / muted speech
- grin + speech combinations
- profile-specific mouth simplifications
- a “mouth occlusion” layer for partial coverage by scarves, microphones, hands, or profile angle loss

That is the level of redundancy that keeps a feature from collapsing when the engine needs a slightly different look than the exact asset sheet.

---

## Proposed architecture: separate mouth engine

### 1) Keep the mouth engine separate

The mouth engine should sit on top of the general animation engine as a focused subsystem:

- **General animation engine**
  - camera
  - blocking
  - pose selection
  - motion paths
  - scene composition

- **Mouth engine**
  - speech/singing analysis
  - viseme generation
  - mouth shape selection
  - angle-aware mouth registration
  - transition timing
  - expression-intensity coupling

This separation is worth keeping because mouth logic has different inputs, different timing, and different quality criteria than body animation.

### 2) Mouth engine inputs

The mouth engine should accept:

- transcript or lyrics
- audio timing or note timing
- phoneme or syllable timing
- language/recognizer data if available
- character head angle
- character expression state
- singing vs speech mode
- projected intensity
- per-character mouth profile

### 3) Mouth engine outputs

The mouth engine should output:

- viseme keyframes
- mouth intensity curves
- transitional hold frames
- angle-specific mouth asset selection
- fallback decisions when assets are missing
- artist-editable metadata

The ideal output is not only “which mouth shape at which frame,” but also:

- how confident the system is
- what fallback it chose
- whether a transition was interpolated or snapped
- whether the line is singing or speech

### 4) Mouth assets should be registered per head angle

Each character should have a mouth profile with:

- a canonical viseme map
- per-angle registration data
- mouth baseline for front / quarter / profile
- optional singing-specific mouth shapes
- optional expression overlays

For example:

- `front`
  - highest fidelity
  - full viseme vocabulary
- `quarterLeft`
  - slightly compressed mouth geometry
  - maybe fewer visual distinctions between similar vowels
- `profileLeft`
  - stronger silhouette-based mouth shapes
  - fewer interior-mouth details

That lets the engine know whether to use a fully detailed mouth or a simpler silhouette-friendly one.

### 5) Use a confidence-aware selection strategy

The engine should never pretend that all mouth mappings are equally reliable.

Suggested confidence logic:

- **high confidence**
  - MBP
  - rest
  - FV
  - clear O / U shapes
- **medium confidence**
  - E vs AI
  - consonant clusters
  - singing sustain shapes
- **lower confidence**
  - quick syllable transitions
  - mixed vowels
  - profile-angle mouth detail

This should affect:

- how long the shape is held
- whether a transition frame is inserted
- whether the mouth uses the “stronger” or “softer” variant

### 6) Make singing a separate timing profile

Speech and singing should share the same mouth assets but not the same timing policy.

For singing:

- lengthen vowel holds
- prefer stable mouth poses on note sustains
- use gentle transitions on note boundaries
- avoid over-snapping every syllable
- let lyrical emphasis drive open-mouth duration

For speech:

- shorter consonant bursts
- more frequent rests
- more aggressive coarticulation
- faster cleanup after consonants

---

## Practical quality targets

For this project, “good” mouth animation does **not** mean perfect phonetics. It means the audience believes the character is speaking or singing.

### Targets for speech

- clear mouth opening on vowels
- stable closed-mouth anchors on MBP
- no jitter during short pauses
- readable from front, quarter, and profile
- minimal popping between visemes
- usable at anime style distance

### Targets for singing

- sustained vowels stay open long enough to read
- consonants do not destroy musical phrasing
- breath and release moments feel intentional
- mouth motion supports the performance instead of distracting from it
- repeated chorus lines can reuse the same mouth pattern if the timing is still clean

### What “anime-caliber” means here

Anime-caliber lip sync does not require hyper-real muscular fidelity. It usually benefits more from:

- clarity
- timing
- clean line stability
- readable vowel shapes
- expressive emphasis

So the engine should prioritize:

1. legibility
2. musicality
3. shape stability
4. artist override control

before trying to maximize phonetic detail.

---

## Recommended package schema additions

The current character-package schema is already close, but for this mouth system I would add a dedicated mouth section.

### Proposed manifest additions

```json
{
  "mouthProfiles": [
    {
      "id": "uuid",
      "name": "Default Anime Mouth Set",
      "defaultAngle": "front",
      "visemes": [
        {
          "name": "rest",
          "role": "viseme",
          "angle": "front",
          "relativePath": "mouth/front/rest.png",
          "placement": {
            "normalizedCenter": { "x": 0.5, "y": 0.62 },
            "normalizedSize": { "width": 0.18, "height": 0.12 }
          }
        }
      ],
      "registration": {
        "front": { "mouthAnchor": [0.5, 0.62], "jawAnchor": [0.5, 0.68] },
        "quarterLeft": { "mouthAnchor": [0.48, 0.63], "jawAnchor": [0.48, 0.69] },
        "profileLeft": { "mouthAnchor": [0.44, 0.64], "jawAnchor": [0.44, 0.70] }
      },
      "singing": {
        "vowelHoldMultiplier": 1.4,
        "consonantSnapMultiplier": 0.8
      }
    }
  ]
}
```

### Why this helps

This makes mouth animation:

- discoverable
- editable
- asset-driven
- angle-aware
- reusable across scenes

And it keeps the package aligned with the rest of the project’s asset philosophy:

- source refs
- base poses
- hero poses
- overlays
- references
- now: mouth profiles

---

## Relationship to AI generation

AI should be used where it helps the package, not where it creates instability.

### Good uses of AI here

- generating reference sheets for mouth sets
- generating missing viseme variants
- creating angle-specific mouth examples
- helping with cleanup of difficult singing shapes
- generating fallback frames for hard transitions

### Bad uses of AI here

- replacing the mouth system entirely with a black box
- generating every frame on demand with no asset grounding
- hiding mouth timing behind a video model when the scene needs editability

The right split is:

- **Mouth engine** = deterministic, asset-grounded, editable
- **AI video** = rescue path for hard shots or missing transitions

That matches the broader plan for the project.

---

## Proposed system behavior in practice

### Example: simple spoken line

Input:
- transcript
- audio
- front-facing character

Pipeline:
1. Rhubarb or another phoneme analyzer produces timed mouth cues
2. `LipSyncEngine` maps cues to Preston Blair visemes
3. Mouth engine picks the front-angle mouth sheet
4. Engine inserts transition frames where needed
5. Renderer overlays the chosen mouth onto the character rig

### Example: sung line

Input:
- lyric text
- note timing
- head angle = three-quarter right
- performance intensity = medium-high

Pipeline:
1. lyric alignment produces note/syllable timing
2. mouth engine expands vowel sustain
3. it chooses the quarter-right mouth variants
4. it keeps mouth openness stable during note holds
5. it subtly relaxes into rest or consonant shapes on phrase ends

### Example: missing mouth angle

If the exact mouth angle is missing:

1. use the nearest available angle
2. apply a registered offset
3. reduce reliance on interior-mouth detail
4. if still weak, fallback to a simpler whole-mouth overlay

This is better than failing outright.

---

## What this means for the project overall

The older assumption that a character package only needs a modest number of parts is too conservative if the goal is a feature-length, semi-autonomous workflow.

For Amira Writer, the package should be understood as a **performance kit**, not just a rig bundle.

It needs:

- body coverage
- head coverage
- angle coverage
- expression coverage
- mouth coverage
- singing coverage
- costume sets
- prop overlays
- AI-assisted fallback generation

In other words:

> The character package is the source of truth for reusable animation performance, and the mouth engine is the subsystem that lets that performance speak and sing convincingly.

---

## Bottom-line recommendation

Build the mouth system as a **separate, asset-driven, angle-aware, confidence-scored engine** that:

- consumes speech or lyric timing
- outputs viseme curves and mouth selection cues
- supports front/quarter/profile mouth assets
- distinguishes speech from singing
- stays editable by an artist
- falls back gracefully when a shape or angle is missing

That gives us a system that is practical for anime-style production, not just technically clever.

---

## Sources reviewed

### Current repo / local code
- `Packages/Animate/Sources/AnimateUI/Services/LipSyncEngine.swift`
- `Packages/Animate/Sources/AnimateUI/Services/RhubarbLipSync.swift`
- `Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`
- `Packages/Animate/Sources/AnimateUI/Rendering/CharacterRenderSelectionContext.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimationAssetRequestPlanner.swift`
- `Packages/Animate/SampleData/CharacterPackages/LukePainterlyV1/character-package.json`

### Primary / authoritative external references
- Adobe Character Animator lip-sync and viseme docs:
  - https://helpx.adobe.com/fi/adobe-character-animator/using/behaviors/body-directly-controlled.html
  - https://helpx.adobe.com/adobe-character-animator/using/prepare-artwork.html
  - https://helpx.adobe.com/bg/adobe-character-animator/how-to/lip-sync-mouth-shapes.html
- Adobe Animate auto lip-sync docs:
  - https://helpx.adobe.com/si/animate/how-to/auto-lip-sync-sensei.html
  - https://helpx.adobe.com/vn_vi/animate/using/symbol-instances.html
  - https://helpx.adobe.com/content/dam/help/en/pdf/animate_reference.pdf
- Toon Boom Harmony lip-sync docs:
  - https://docs.toonboom.com/help/harmony-22/advanced/sound/about-lip-sync.html
  - https://docs.toonboom.com/help/harmony-20/advanced/sound/map-lip-sync-detection.html
  - https://docs.toonboom.com/help/harmony-20/essentials/sound/manual-lip-sync.html
  - https://docs.toonboom.com/help/harmony-24/essentials/sound/change-sound-display.html
- Rhubarb Lip Sync:
  - https://github.com/DanielSWolf/rhubarb-lip-sync
- Research on visual speech synthesis / co-articulation:
  - https://www.sciencedirect.com/science/article/abs/pii/S0885230818300275
  - https://arxiv.org/abs/1805.09488
  - https://dgp.toronto.edu/~elf/JALISIG16.pdf

