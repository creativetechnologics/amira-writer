# Hybrid Animation Pipeline Research

## Purpose

This document collects the working research for a **semi-autonomous 2D animation pipeline** that combines:

- an internal rig / coordination engine for the majority of shots
- a separate mouth / lip-sync engine for dialogue and singing
- AI video generation for difficult or expensive shots
- AI image generation for reference sheets, costume variants, pose exploration, and asset iteration

The goal is not to replace the animation engine with AI video.
The goal is to build a pipeline where the internal system handles most of the series, while AI video is reserved for the shots that are hardest to animate, hardest to revise, or cheapest to externalize.

---

## Executive Summary

The strongest production strategy is a **hybrid**:

1. **Internal 2D rig engine**
   - handles dialogue, staging, body motion, reusable acting, and continuity-heavy scenes
   - should be driven by a structured shot plan rather than freeform keyframes alone

2. **Separate mouth engine**
   - handles visemes, singing mouths, and angle-aware mouth selection
   - should be reusable across the internal rig engine and AI-assisted output

3. **AI video layer**
   - handles difficult shots:
     - complex motion
     - crowds
     - atmospheric transitions
     - moving camera shots
     - shots where internal rigging would be too time-consuming or too fragile

4. **AI image layer**
   - generates the canonical character sheets, turnaround sheets, costume sheets, props, and reference variants that feed both the rig system and the video system

The key design principle is:

> **The internal engine owns the film grammar. AI video fills the gaps.**

---

## What the official docs imply

Google’s current video docs matter because they define what external video models can realistically do today.

### Veo / Flow capabilities that are useful for this pipeline

From Google’s official docs and product updates:

- **Reference images can guide subject and style**
  - Veo on Vertex AI supports reference images for directing generated content and artistic style.
  - Subject reference mode can take **up to three images** of a single person / character / product.
  - Style reference is supported in older Veo 2 flows, while Veo 3.1 emphasizes asset / subject guidance.

- **First-frame / last-frame workflows exist**
  - Veo supports generating video from an image as the starting frame.
  - Preview APIs support **first frame** and **last frame** control.
  - This is useful for shot bridging, transitions, and camera-move continuity.

- **Prompt for motion, not repeated description**
  - Google’s best-practice docs explicitly recommend describing motion, camera movement, and environmental changes rather than re-describing the subject and setting already present in the source image.

- **Use general terms for the character in the motion prompt**
  - Google recommends using generic subject language like “the subject,” “the woman,” “he,” “she,” or “they.”
  - This aligns with our own prompt rewrite preference: do not rely on character-name shorthand in downstream video prompts.

- **Short clips are the model’s natural unit**
  - Veo is a short-clip tool, not a feature-film engine.
  - That means we should route only the expensive or hard-to-animate moments into Veo, not the whole movie.

### What this means for our architecture

The internal engine should produce:

- clean reference sheets
- shot plans
- start-frame and end-frame stills
- pose coverage
- camera coverage
- mouth timing
- confidence scores

Then the AI video layer should consume those outputs when a shot is flagged as:

- too complex
- too fluid
- too crowd-heavy
- too expensive to author by hand
- or too risky to hand-rig in the current schedule

---

## Recommended pipeline structure

### Layer 1 — Canonical character asset system

This is the asset bible.
It contains the durable visual truth for each character:

- identity reference
- master sheet
- head turnaround sheet
- full-body / costume sheets
- expressions
- visemes
- hands
- props
- accessory states
- wardrobe variants
- approved poses

This layer is where Nano Banana-style image workflows are most valuable.
It is also where human QA matters most.

### Layer 2 — Internal animation coordination engine

This engine decides:

- what motion should happen
- which assets are needed
- which pose or keyframe is the canonical source
- what camera movement is allowed
- what mouth shapes are needed
- which shot can be solved with reusable rig parts

The coordination engine should not be a passive timeline-only tool.
It should be able to turn a text instruction such as:

- “Luke walks across the frame and looks toward the door”

into a structured shot plan with:

- start pose
- end pose
- body path
- head orientation
- arm events
- prop events
- camera motion
- mouth timing
- fallback status

### Layer 3 — Separate mouth engine

This is intentionally a separate subsystem.
It should own:

- viseme mapping
- phoneme / lyric alignment
- singing mouth shapes
- head-angle-aware mouth asset selection
- mouth placement on the face
- confidence scoring and fallbacks

The mouth engine should be usable by:

- the internal rig engine
- shot previews
- AI-generated shots that still need mouth overlay or correction

### Layer 4 — AI video fallback / enhancement layer

This layer is not the default.
It is the exception path.

Use it when:

- the motion is too complex for the current rig system
- the camera move is too elaborate
- the shot depends on atmosphere or FX more than character acting
- the scene needs a rapid proof-of-concept
- the user wants a quick advanced shot rather than a precisely editable rig shot

---

## How much character packaging is actually needed?

The earlier instinct that “it is only a few parts” is too optimistic for feature work.

At the same time, the answer is **not** “every possible pose as a separate asset.”

The right answer is a **coverage matrix**.

### Minimum viable character package

For a character to be truly usable in a semi-autonomous 2D engine, the package should include:

#### Identity / orientation
- front neutral
- front smiling
- quarter-turn left
- quarter-turn right
- side profile left
- side profile right
- back

#### Close-up identity
- face front neutral
- face smiling
- face quarter-turn left
- face quarter-turn right
- face side left
- face side right
- back of head

#### Expressions
- neutral
- happy
- sad
- angry
- worried
- surprised
- tired
- determined
- laughing
- singing

#### Visemes / mouth shapes
- rest
- vowel-open
- vowel-wide
- vowel-round
- consonant-closed
- labial close
- fricative shape
- soft open
- singing sustain
- singing close

#### Body / action coverage
- standing neutral
- walking
- stopping / turning
- reaching
- pointing
- seated
- kneeling
- holding prop
- carrying bag
- gesturing

#### Costume variants
- primary outfit
- civilian outfit
- alternate outerwear
- wet / dusty / damaged state where needed

#### Hands / props / accessories
- open hand
- pointing hand
- holding hand
- relaxed hand
- glove variant
- satchel / bag
- scarf / jacket / coat overlay

#### Background / place support
- key set plates
- clinic
- street
- interior
- exterior
- night / day / weather variants

This is more than the current proof-of-concept package, but it is still finite and manageable.

### What the package should not become

Do **not** build a separate unique image for every frame of every shot.

That would destroy:

- maintainability
- regeneration speed
- consistency
- human approval speed

Instead, build reusable **asset families** with a strong registration system.

---

## What the current sample Luke package teaches us

The sample Luke package in the repo is a useful proof-of-concept, but it is not yet a feature-grade package.

It currently demonstrates:

- reference images
- a base pose
- a turnaround anchor
- a few hero poses
- a few part overlays

That is enough to prove the architecture.

It is **not enough** to support a full show unless it expands into:

- more angle variants
- more costume states
- more hands
- more facial/viseme coverage
- more pose-specific detail
- better anchor metadata
- better package manifest semantics

The important lesson is that the package must be:

- modular
- versioned
- inspectable
- regeneratable
- and aware of pose / angle / costume state

---

## Mouth engine: why it should be separate

This deserves its own subsystem.

### Why separate it?

Because mouth animation is not the same problem as body animation.

The mouth engine needs to reason about:

- text or lyrics
- phoneme timing
- visemes
- sustained vowels
- consonant closures
- expression blending
- head angle
- face orientation
- camera distance

That logic will be reused across:

- dialogue scenes
- singing scenes
- close-ups
- medium shots
- AI-assisted output

If mouth logic is baked into the same engine that handles body motion, you lose reuse and make the system harder to tune.

### Recommended mouth-engine architecture

#### Inputs
- transcript or lyrics
- audio timing
- speaking rate
- character id
- shot id
- head angle
- face orientation
- emotional state
- camera distance

#### Core steps
1. Align text/audio to phoneme or beat intervals.
2. Convert intervals to viseme classes.
3. Choose the best mouth asset for the current head angle.
4. Apply mouth placement anchored to the face registration points.
5. Blend in emotion if the shot needs it.
6. Emit a time-coded mouth plan.

#### Outputs
- viseme keyframes
- mouth sprite or layer ids
- mouth confidence score
- optional manual override notes
- fallback recommendations

### Singing-specific behavior

Singing is not just “talking on music.”

It needs:

- longer vowel sustain
- more open vowel shapes
- fewer closure transitions
- smoother switching between adjacent vowels
- occasional exaggeration for readability

So the mouth engine should distinguish:

- dialogue phoneme mapping
- singing phoneme mapping

That can be one system with two operating modes.

### Orientation-aware mouth placement

The mouth engine should not assume a single face angle.

It should have:

- angle-specific mouth atlases
- angle-specific anchor points
- fallback interpolation between angles

Example:

- front
- quarter-left
- quarter-right
- side-left
- side-right

Each head pose should carry:

- face anchor position
- mouth anchor position
- scale factor
- rotation / skew hints
- confidence per angle

That lets the engine keep the mouth locked even when the head turns.

---

## Data interfaces the systems should expose

The main mistake to avoid is making the animation engine “smart” in the abstract but vague in the data.

It needs concrete contracts.

### 1) CharacterPackage manifest

This is the source of truth for reusable visual assets.

Suggested fields:

```json
{
  "schemaVersion": 1,
  "characterId": "uuid",
  "characterSlug": "luke-hart",
  "displayName": "Luke Hart",
  "packageVersion": "1.0.0",
  "packageKind": "hero",
  "styleFamily": "anime-grounded-2d",
  "approvedMasterSheetPath": "...",
  "approvedHeadSheetPath": "...",
  "approvedBodySheets": [],
  "expressions": [],
  "visemes": [],
  "poses": [],
  "costumes": [],
  "props": [],
  "metadata": {
    "sourceImages": [],
    "promptHistory": [],
    "approvedBy": [],
    "notes": ""
  }
}
```

### 2) Pose slot metadata

Each pose should know:

- title
- angle
- shot type
- costume set
- preferred duration
- priority
- canonical status
- approved variant
- fallback variant

Example:

```json
{
  "id": "uuid",
  "title": "Walking",
  "angle": "threeQuarterFront",
  "costumeSet": "military",
  "category": "body",
  "recommendedDurationFrames": 48,
  "approvedVariantId": "uuid",
  "fallbackVariantId": "uuid",
  "coverageTags": ["dialogue", "movement", "scene-blocking"]
}
```

### 3) Shot plan from the LLM

The coordination engine should accept a structured plan, not just prose.

Suggested fields:

```json
{
  "sceneName": "Luke crosses clinic street",
  "characters": [
    {
      "characterId": "uuid",
      "role": "lead",
      "wardrobe": "civilian",
      "startingPose": "neutral-stand-front",
      "endingPose": "walking-threeQuarterLeft"
    }
  ],
  "camera": {
    "type": "dolly",
    "direction": "leftToRight",
    "speed": "slow"
  },
  "motion": {
    "pathPoints": [
      {"x": 0.2, "y": 0.7, "frame": 0},
      {"x": 0.6, "y": 0.7, "frame": 48}
    ]
  },
  "mouth": {
    "mode": "dialogue",
    "source": "transcript",
    "confidence": 0.87
  },
  "useAiVideoFallback": false,
  "notes": "Keep acting restrained and realistic."
}
```

### 4) AI video handoff payload

For Veo / Flow / other external video systems, the handoff should include:

- title
- prompt
- reference images
- start frame
- end frame
- optional style refs
- aspect ratio
- duration
- seed
- motion notes
- continuity notes

This payload should be capability-driven, not vendor-driven.

That means the internal system should be able to ask:

- can this model accept a subject reference?
- can it accept start frame?
- can it accept end frame?
- can it accept style reference?
- how many refs?
- what duration?

and then assemble the request accordingly.

---

## How to keep style continuity across internal and AI-generated shots

This is one of the most important parts of the whole pipeline.

### 1. Use a canonical approved sheet per character

Every character needs a locked identity package:

- master sheet
- head sheet
- costume sheet
- approved color palette
- approved proportions
- approved facial landmarks

This is the core style anchor.

### 2. Keep prompt language explicit

Do not rely on shorthand project names or internal nicknames in prompts.

Instead, use explicit visual descriptions:

- early-2000s Afghanistan war setting
- dusty clinic street
- concrete / mud-brick architecture
- realistic modern fabrics
- muted desert tones
- humanitarian and military presence

This gives the model the actual visual semantics rather than an opaque project label.

### 3. Use references intentionally, not loosely

For video generation, the strongest pattern is:

- one subject reference sheet
- one costume / wardrobe sheet if needed
- one environment / place reference if needed
- optional start frame or end frame

Avoid overloading the model with many redundant refs.

### 4. Prompt motion only for image-to-video

If the source image already fixes the character, costume, and style, the motion prompt should stay focused on motion.

Good motion prompts mention:

- camera move
- body motion
- atmospheric motion

They do **not** re-describe the character every time.

### 5. Keep a human approval gate

The approved asset is not “whatever the model made.”

It is the result of:

- generation
- review
- selection
- promotion

That approval step is what keeps style continuity stable across the show.

---

## When to use internal rig animation vs AI video

This should be a routing decision, not a philosophical debate shot by shot.

### Use the internal rig engine when:

- dialogue is the focus
- continuity is critical
- lip sync matters
- the shot will be revised a lot
- the camera is modest
- the motion is readable via rig layers
- the shot reuses existing assets
- the cost of manual control matters more than raw motion complexity

### Use AI video when:

- the shot has difficult motion the rig cannot credibly produce
- there is a crowd or busy environment
- the camera move is hard to author or simulate cleanly
- the scene is atmospheric and short
- the transition itself is the effect
- the internal engine would take too long to set up

### Use hybrid when:

- the character must stay visually consistent, but the environment or motion is hard
- the body is controlled internally, but the background or transition is external
- you need a start frame and end frame to bridge a gap
- a scene needs a strong canonical pose plus AI motion fill

### Use full AI video only when:

- the shot is a montage piece
- the sequence is intentionally impressionistic
- the motion is more important than exact editability
- the shot is not likely to need frame-by-frame revision

---

## Decision framework for routing a shot

This is the operational rule set.

### Step 1 — Ask what must remain exact

If the shot must preserve:

- exact mouth timing
- exact hand choreography
- exact prop placement
- exact costume state
- exact camera beat timing

then the internal engine should own it.

### Step 2 — Ask what is hardest about the shot

If the hardest part is:

- character acting
- lip sync
- line delivery
- subtle body language

use the internal rig and mouth engine.

If the hardest part is:

- motion complexity
- camera speed
- environment chaos
- FX
- crowd energy

use AI video or hybrid.

### Step 3 — Ask how likely the shot is to be revised

If the shot is likely to be reblocked many times, keep it internal.

If the shot is a one-off insert, AI video is a better candidate.

### Step 4 — Ask if a start/end bridge solves it

If a good start frame and end frame would solve the shot, consider AI video.

If the scene needs precise in-between acting, keep it internal.

### Step 5 — Ask if the shot can be split

Often the best answer is not “internal or AI.”

It is:

- internal for the actor
- AI for the atmospheric bridge
- internal again for the close-up

That kind of shot decomposition should be a first-class workflow.

### Simple routing matrix

| Shot type | Default route |
|---|---|
| Dialogue close-up | Internal rig + mouth engine |
| Slow walk-and-talk | Internal rig |
| Medium shot with prop handling | Internal rig |
| Crowd action / chaos | AI video or hybrid |
| Fast cinematic move | AI video |
| Establishing shot | AI video or internal plate + parallax |
| Repeated revision shot | Internal rig |
| Singing close-up | Internal rig + mouth engine |
| Transition bridge | Hybrid |

---

## How start/end frames should be used

Start/end frames are not just a convenience.
They are a bridge between the two systems.

### Recommended use

- **Start frame**: the canonical approved pose or frame the shot begins from
- **End frame**: the canonical approved target pose or frame the shot should reach

This helps when:

- you want a motion bridge
- the shot must transition from one state to another
- the video model needs a stronger continuity anchor

### Best practice

Use the start and end frames from the same character package whenever possible.

That means:

- same approved face
- same costume state
- same palette
- same relative framing

This reduces the risk of style drift.

### For our pipeline

The internal engine should be able to export:

- canonical start-frame stills
- canonical end-frame stills
- reference sheets
- prompt text
- shot notes

The AI video adapter should then consume those with the best model capabilities available at the time.

---

## Future-proofing the pipeline

This part matters because the model landscape changes quickly.

### 1. Build around capabilities, not brand names

Do not hardcode the pipeline around one model family.

Instead, define capability flags like:

- acceptsSubjectReferences
- acceptsStyleReferences
- acceptsStartFrame
- acceptsEndFrame
- supportsFrameExtension
- supportsAudio
- supportsBatching
- supportsMultipleReferenceImages

The route planner should use these flags.

### 2. Version every asset family

Every package should know:

- schema version
- prompt version
- approved variant version
- export version

That makes migration possible without losing history.

### 3. Keep provenance

Every generated asset should record:

- source refs
- prompt
- model id
- aspect ratio
- duration or size
- seed if available
- approval status

That makes it possible to recreate and audit later.

### 4. Separate canonical assets from exploratory assets

There should always be a distinction between:

- exploratory generation
- approved master assets
- downstream render assets

This prevents accidental promotion of a bad variant.

### 5. Preserve human approval

No matter how good the AI becomes, the last mile for a feature should still have a human-selected canonical asset.

The system can be highly automated.
It should not be fully ungoverned.

### 6. Keep the mouth engine independent

The mouth system will evolve separately from the body / camera system.

It should be able to survive changes in:

- rig format
- rendering format
- video model vendor
- shot routing policy

---

## Recommended research-backed implementation order

If we were building this in the codebase later, the order should be:

1. **Character package manifest v2**
   - add explicit asset families, angle tags, costume tags, and approval states

2. **Shot plan schema**
   - structured text-to-shot interface for the coordination engine

3. **Mouth engine v1**
   - visemes, phoneme/lyric alignment, angle-aware mouth selection

4. **AI video handoff adapter**
   - a capability-driven wrapper for start/end frames and reference images

5. **Shot routing engine**
   - internal vs hybrid vs AI decision logic

6. **QA / promotion workflow**
   - approve canonical variants and lock them as production references

---

## Practical conclusion

The research points to a very specific answer:

- The **internal engine** should own most animation
- The **mouth engine** should be a separate subsystem
- The **AI video layer** should be an escape hatch and enhancement layer
- The **character package** must be more complete than the current proof-of-concept sample
- The system should route by **shot requirements**, not by hype

If we do this well, the result is a production stack where:

- simple and repeated scenes are cheap and editable
- singing and dialogue are synchronized enough for anime-grade readability
- difficult shots can still be generated when needed
- style continuity remains under our control

That is the right long-term architecture for this project.

---

## Sources

Official and primary sources used for this research:

- Google Cloud — Veo reference images for video generation  
  https://cloud.google.com/vertex-ai/generative-ai/docs/video/use-reference-images-to-guide-video-generation

- Google Cloud — Veo best practices on Vertex AI  
  https://docs.cloud.google.com/vertex-ai/generative-ai/docs/video/best-practice

- Google Cloud — Veo video generation API reference  
  https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/veo-video-generation

- Google Cloud — Generate videos with first and last frames  
  https://docs.cloud.google.com/vertex-ai/generative-ai/docs/video/generate-videos-from-first-and-last-frames

- Google Blog — Flow adds speech and expands  
  https://blog.google/technology/google-labs/flow-adds-speech-expands/

- Google Blog — Veo 3.1 Ingredients to Video  
  https://blog.google/innovation-and-ai/technology/ai/veo-3-1-ingredients-to-video/

- Google AI Developers — Gemini image generation / editing  
  https://ai.google.dev/gemini-api/docs/image-generation

- Adobe Animate — Auto lip sync / symbol instances  
  https://helpx.adobe.com/ee/animate/how-to/auto-lip-sync-animation.html  
  https://helpx.adobe.com/lv/animate/using/symbol-instances.html

- Toon Boom Harmony — Lip-sync and cut-out rigging docs  
  https://docs.toonboom.com/help/harmony-21/premium/cut-out-animation/animate-lip-sync.html  
  https://docs.toonboom.com/help/harmony-24/premium/reference/node/constraint/constraint-node.html

