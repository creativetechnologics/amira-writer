# AI-Assisted Character Asset Generation Pipeline

## Purpose

This document defines a practical research-backed approach for building semi-autonomous 2D animation character packages for *Amira Writer*.

The goal is not “one magic model that animates everything,” but a layered system that combines:

- AI-generated reference sheets and variant assets
- structured character package manifests
- slot/skin-based runtime assembly
- lip-sync / mouth-shape tooling
- human approval and QA checkpoints
- targeted video-generation fallback for hard shots

The core thesis is:

> Use AI to produce and iterate the assets, but keep the runtime animation system deterministic and slot-driven.

---

## Executive summary

The most effective workflow for this project is:

1. **Curate identity references first**
   - 1–3 strong face/pose references per character
   - one canonical master reference sheet

2. **Generate structured asset families**
   - turnarounds
   - full-body pose sheets
   - expressions
   - visemes / mouth shapes
   - costume variants
   - accessories / props
   - hand/gesture variants
   - part extraction layers for rig assembly

3. **Approve and version the best outputs**
   - one approved master sheet becomes the canonical source
   - all downstream assets should reference approved sheets, not random prior generations

4. **Assemble the runtime package around slots, skins, and placement data**
   - the animation engine should know *what* asset to swap in, *where* it belongs, and *which* variant is approved
   - don’t hardcode one-off images into scene logic

5. **Separate the mouth/lip-sync engine**
   - body animation and mouth animation should be distinct layers
   - mouth assets need their own angle-aware registration and phoneme mapping

6. **Use AI video selectively**
   - reserve video models for shots that are hard to solve with the package system
   - use start/end frames and reference images when necessary

This is consistent with Google’s multimodal image tooling, the Toongether Gemini case study, and classical cut-out / slot-based animation systems.

---

## What the official docs imply

### 1) Gemini image models are suitable for reference-sheet workflows

Google’s Gemini image generation docs explicitly support:

- text + image generation/editing
- multiple images in a single prompt
- aspect ratios such as `1:1`, `2:3`, `3:2`, `4:3`, `16:9`, `21:9`
- image sizes `1K`, `2K`, `4K`
- reusable file uploads via the File API

That makes Gemini well-suited for:

- master reference sheets
- pose sheets
- sheet edits
- costume variations
- accessory-focused generations

Sources:

- [Image generation with Gemini (Nano Banana / Nano Banana Pro)](https://ai.google.dev/gemini-api/docs/image-generation)
- [Image understanding / multiple images / File API guidance](https://ai.google.dev/gemini-api/docs/vision)
- [Generating content API reference (image config: aspect ratio and size)](https://ai.google.dev/api/generate-content)
- [Using files / File API](https://ai.google.dev/api/files)

### 2) Batch mode is appropriate for large asset runs, but it is not idempotent

Google’s Batch API is explicitly intended for high-volume, non-urgent workloads, and the docs call out that:

- it runs at reduced cost relative to standard API usage
- JSONL input files are recommended for large jobs
- large jobs should be split when needed
- **creating the same batch job twice creates two separate jobs**

That matters for character packages because large pose/asset runs can become expensive fast.

Source:

- [Gemini Batch API](https://ai.google.dev/gemini-api/docs/batch-api)

### 3) Gemini’s reference-image workflows reinforce the “curated neutral sheet + asset pack” pattern

Google’s Toongether case study is especially relevant. Their pipeline uses:

- a curated reference set to analyze style
- a neutral pose reference image for the character
- instruction prompts to generate scenarios without losing identity
- asset packs for grouped poses and use cases

That is very close to the approach needed here.

Source:

- [Toongether case study](https://ai.google.dev/showcase/toongether)

### 4) Cut-out animation systems are slot-based, not “one image per shot”

Toon Boom Harmony documentation shows the traditional cut-out approach:

- animations swap drawings in columns/layers
- lip sync fills a mouth layer with mouth drawings
- a mouth chart maps phonemes to mouth shapes

This is the right mental model for a semi-autonomous 2D system:

- body parts become swappable layers
- mouth shapes become a separate layer bank
- timing/keyframes drive exposure changes

Sources:

- [Harmony lip-sync documentation](https://docs.toonboom.com/help/harmony-21/premium/cut-out-animation/animate-lip-sync.html)
- [Harmony cut-out animation overview](https://docs.toonboom.com/help/harmony-22/premium/getting-started/cut-out.html)
- [Harmony lip-sync overview](https://docs.toonboom.com/help/harmony-21/premium/sound/about-lip-sync.html)

### 5) Skin/slot systems from rig runtimes map well to costume and accessory variants

Spine’s docs describe skins as maps from slots to attachments. That is useful because it decouples:

- animation logic
- the specific attachment shown in a slot
- wardrobe/costume selection

That maps well to this project’s needs:

- the runtime should know the `mouth` slot, `head` slot, `torso` slot, etc.
- each costume pack can swap in different attachments without changing animation logic

Sources:

- [Spine skins](https://esotericsoftware.com/spine-skins)
- [Spine runtime skins](https://esotericsoftware.com/spine-runtime-skins)
- [Spine attachments](https://esotericsoftware.com/spine-attachments)

---

## Research conclusions

### A. A “character package” should be broader than a simple model sheet

For feature use, a character package should include more than:

- one front pose
- one side pose
- one drawing

It should include several asset families:

1. **Identity anchors**
   - face close-ups
   - neutral front sheet
   - 3/4 front and profile views

2. **Turnaround / staging views**
   - full-body front / side / back
   - seated and action-neutral staging poses

3. **Expression banks**
   - neutral
   - happy
   - angry
   - sad
   - worried
   - surprised
   - yelling / shouting
   - laugh / smile variations

4. **Mouth / viseme banks**
   - rest
   - open vowel shapes
   - rounded vowels
   - consonant closures
   - teeth-visible shapes
   - singing-specific shapes

5. **Costume variants**
   - soldier / medic wardrobe
   - civilian wardrobe
   - cold-weather / covered / tactical variants if needed

6. **Accessory packs**
   - satchel / bag
   - scarf
   - gloves
   - weapons or tools if applicable
   - props

7. **Part extraction layers**
   - head
   - face
   - hair front/back
   - torso
   - shoulders
   - upper/lower arms
   - hands
   - hips
   - legs / feet

8. **Registration and placement metadata**
   - where each layer sits in the frame
   - anchor points
   - camera-facing angle
   - version info

### B. The package should be versioned and approval-driven

AI generation is too drift-prone to trust the first output.

So the package should be built around:

- **generated variants**
- **approved variants**
- **source provenance**
- **regeneration history**
- **schema versioning**

That allows the user to:

- keep multiple candidates
- compare them
- approve the best one
- regenerate missing or weak pieces later

### C. The mouth engine should be separate from the body engine

This is a strong recommendation.

The mouth system has different needs than the body system:

- it is highly time-sensitive
- it depends on transcript or lyric alignment
- it must match character orientation and head angle
- it often needs far fewer pixels than the body
- it benefits from its own fallback rules and QA loop

For that reason, mouth generation should be its own subsystem, even if it uses the same asset library.

---

## Proposed package architecture

### 1) Core package layers

Each character package should be organized into logical layers:

- `identity/`
  - canonical face and body references
  - master sheet
  - approved sheet variants

- `turnarounds/`
  - front
  - 3/4 front
  - side
  - 3/4 back
  - back

- `poses/`
  - neutral standing
  - walking
  - talking
  - seated
  - reaching
  - action beats

- `expressions/`
  - emotion cards
  - brows / eye shapes
  - laugh / shout / concern

- `mouth/`
  - viseme set
  - angle-specific mouth registration
  - singing mouth shapes

- `costumes/`
  - one subfolder per wardrobe set
  - full-body turnarounds and pose cards per wardrobe

- `accessories/`
  - bag, gloves, scarf, tools, props

- `parts/`
  - extracted rig layers
  - angle-specific or costume-specific where needed

- `metadata/`
  - prompts
  - approval history
  - generation config
  - source refs
  - QA notes

### 2) Suggested manifest shape

The package manifest should track more than file paths. It should store:

- character identity
- source references
- approved master sheet IDs
- approved costume sheet IDs
- approved mouth bank IDs
- asset categories
- transform/placement metadata
- provenance
- generation prompts
- QA status

Example conceptual schema:

```json
{
  "character": {
    "name": "Luke Hart",
    "identitySlug": "luke-hart",
    "storageSlug": "luke-hart",
    "wardrobes": [
      {
        "id": "soldier",
        "name": "Soldier",
        "masterSheet": "...",
        "turnarounds": [...],
        "poses": [...],
        "accessories": [...]
      },
      {
        "id": "civilian",
        "name": "Civilian",
        "masterSheet": "...",
        "turnarounds": [...],
        "poses": [...],
        "accessories": [...]
      }
    ],
    "mouthBank": {
      "baseVisemes": [...],
      "singingVisemes": [...],
      "angleAnchors": {...}
    },
    "provenance": {...},
    "qa": {...}
  }
}
```

The exact schema can evolve, but the principle is the important part:

> The package must know *what the asset is*, *what wardrobe it belongs to*, *what angle it represents*, and *whether it is approved*.

---

## Recommended generation pipeline for this project

### Stage 0: Reference curation

Before generating anything, collect:

- one or more clean face references
- one or more body references
- wardrobe references for each costume set
- any prop references
- style references

Rules:

- use a small curated set, not an unbounded pile
- avoid feeding previous bad generations back into the same request stream
- keep the master references separate from inspiration variants

### Stage 1: Generate a canonical master sheet

Use Gemini image generation to create a **single approved character reference sheet**:

- multi-view
- consistent outfit
- clean white or light background
- explicit identity lock
- explicit turn directions

This sheet becomes the canonical reference for later generation.

Best practice from the research:

- one neutral pose reference
- one instruction prompt
- carefully selected supporting refs

### Stage 2: Approve the master sheet

Do not allow every generated sheet to become canonical.

Instead:

- generate several variants
- compare them
- choose one approved master sheet
- keep the others as candidates

This is essential because AI outputs drift.

### Stage 3: Generate the pose library

From the approved master sheet, generate:

- full-body turnarounds
- pose cards
- action-neutral staging poses
- head turnarounds

These should be driven by a shared prompt template and one shared config block per run, with only the per-pose prompts changing.

### Stage 4: Generate costume variants

For each wardrobe:

- generate a wardrobe-specific master sheet
- generate the corresponding pose library
- generate any costume overlays or accessories

Important:

- treat wardrobe as a package dimension, not a separate character identity
- keep the face/identity shared across wardrobe variants

### Stage 5: Extract parts / build rig assets

Use the approved images to create:

- head and face crops
- torso / shoulder / arm / hand crops
- angle-specific parts when needed
- transparent part layers

This is where a human QA loop matters a lot:

- check edge cleanliness
- check cropping
- check silhouette preservation
- check that the part still reads at runtime

### Stage 6: Generate mouth banks separately

Do not wait until the body rig is fully solved before creating mouth assets.

The mouth system should be its own bank:

- visemes
- singing mouth shapes
- maybe a few expression+mouth composites

It should support:

- face orientation
- head angle
- light rotation/turning
- lyric timing

### Stage 7: Integrate into scenes and test

Once assets exist, test them in a real scene:

- walk cycle
- talking close-up
- singing medium shot
- turning head
- costume change
- prop interaction

The QA goal is not perfect animation from day one.

The QA goal is:

- no identity drift
- no costume drift
- no broken mouth placement
- no unusable layers

### Stage 8: Use AI video only for the hard gaps

When the package system cannot solve a shot elegantly:

- use start/end frame generation
- use reference images
- use a video model for the hard transition or effect-heavy motion

This keeps the expensive video path as a fallback instead of the default.

---

## Human QA loops that are still required

AI can accelerate creation, but the following checks should remain human-reviewed:

### 1) Identity QA

Check:

- face likeness
- hairline
- age
- build
- proportions
- signature clothing details

Reject assets that drift too far from the approved identity.

### 2) Costume QA

Check:

- wardrobe consistency
- pocket placement
- straps
- boots
- accessories
- uniform vs civilian readability

Costume drift is especially likely when the model is asked to combine multiple refs.

### 3) Pose QA

Check:

- whether the pose is actually the requested pose
- whether left/right orientation is correct
- whether the silhouette is readable
- whether the pose can work in a rig

### 4) Part extraction QA

Check:

- no accidental clipping
- transparent edges are clean
- limbs are cleanly separated
- no missing fingers/shoulders/hair regions

### 5) Mouth / lip-sync QA

Check:

- mouth anchor position
- angle correctness
- shape readability at runtime
- vowel clarity
- consonant closure timing

### 6) Scene QA

Check:

- whether the assembled character still reads correctly in motion
- whether the part stack looks natural
- whether the motion feels anime-caliber rather than robotic

### 7) Regression QA

Whenever a new generation style is approved, compare it against prior approved assets to ensure the package still matches.

---

## Mouth engine design recommendation

The mouth engine should be a distinct module layered on top of the body animation engine.

### Responsibilities

The mouth engine should:

- read lyrics or transcript text
- align text to frames or beats
- select visemes / singing mouth shapes
- choose mouth shapes based on character angle
- place the mouth correctly on the current head orientation
- optionally choose more expressive mouth variants for singing

### Inputs

- character identity
- head angle
- current pose
- lyric/transcript timing
- audio timing if available
- approved viseme set

### Outputs

- mouth asset ID
- frame range
- placement transform
- confidence / fallback flag

### Why this should be separate

The body animation engine and the mouth engine have different failure modes:

- body engine failures are often silhouette or pose problems
- mouth engine failures are often timing, phoneme, or registration problems

Separating them keeps the system simpler and more debuggable.

---

## Practical package size guidance

The exact number of assets is less important than the structure, but a feature-grade package will often need more than a minimal demo rig.

As a rough target per character:

- 1 canonical identity sheet
- 1–2 approved wardrobe master sheets
- 5 full-body turnaround views per wardrobe
- 6–12 pose cards per wardrobe
- 8–15 expressions
- 8–15 visemes / mouth shapes
- 5–15 accessory/prop states
- 10–20 body-part or layer assets, depending on rig style

That means a production-grade character package can easily become a **multi-dozen to low-hundreds** asset set once you include costumes and mouth banks.

The key point is not “generate everything at once.”

The key point is:

> generate the package in organized layers that the runtime can actually reason about.

---

## Recommended implementation strategy in *Amira Writer*

The current app architecture should evolve toward:

1. **Character identity**
   - saved source identity
   - storage slug
   - wardrobe type
   - reference sheet approval state

2. **Generation jobs**
   - one shared config block per batch
   - per-prompt variation underneath
   - explicit prompt provenance and estimated cost

3. **Approval states**
   - generated
   - selected
   - approved
   - deprecated

4. **Per-family asset groups**
   - master sheet
   - head sheet
   - costume sheet
   - accessories
   - mouth bank

5. **Scene integration**
   - deterministic runtime lookup
   - fallback selection rules
   - reference provenance visible to the user

This aligns with the already-built Animate workflow ideas:

- generation preflight
- variant approval
- copy/export/import support
- per-character configuration
- batch watchdog support

---

## Concrete recommendations for this project

1. **Treat the master sheet as canonical**
   - do not let random generated variants silently become the source of truth

2. **Keep one base identity with multiple wardrobe packs**
   - soldier/civilian is a wardrobe axis, not a separate person

3. **Use one shared generation config per set**
   - model / aspect ratio / size / ref images should be global to the run
   - only prompts vary per pose/item

4. **Build a separate mouth engine**
   - do not bury mouth logic inside the main body-rigging system

5. **Use video generation only where the package system struggles**
   - especially for difficult motion blends and transitions

6. **Maintain human approval checkpoints**
   - AI assists, but humans select the best assets

7. **Version everything**
   - prompt version
   - sheet version
   - asset version
   - package version
   - schema version

---

## Sources

- [Image generation with Gemini (Nano Banana / Nano Banana Pro)](https://ai.google.dev/gemini-api/docs/image-generation)
- [Image understanding / multiple images](https://ai.google.dev/gemini-api/docs/vision)
- [Generating content API reference (aspect ratio, image size)](https://ai.google.dev/api/generate-content)
- [Using files / File API](https://ai.google.dev/api/files)
- [Gemini Batch API](https://ai.google.dev/gemini-api/docs/batch-api)
- [Toongether case study](https://ai.google.dev/showcase/toongether)
- [Harmony lip-sync documentation](https://docs.toonboom.com/help/harmony-21/premium/cut-out-animation/animate-lip-sync.html)
- [Harmony cut-out animation overview](https://docs.toonboom.com/help/harmony-22/premium/getting-started/cut-out.html)
- [Harmony lip-sync overview](https://docs.toonboom.com/help/harmony-21/premium/sound/about-lip-sync.html)
- [Spine skins](https://esotericsoftware.com/spine-skins)
- [Spine runtime skins](https://esotericsoftware.com/spine-runtime-skins)
- [Spine attachments](https://esotericsoftware.com/spine-attachments)

---

## Working conclusion

The best system for this project is not “fully automatic animation.”

It is:

- AI-assisted asset generation
- curated, approved reference sheets
- slot/skin-based character packages
- a separate mouth/lip-sync layer
- strong human QA
- video generation only for the hardest shots

That combination is the most realistic path to consistent, anime-caliber, semi-autonomous 2D production.
