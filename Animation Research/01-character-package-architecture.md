# Character Package Architecture Research

**Project:** Amira Writer / Animate
**Date:** 2026-03-30
**Scope:** Semi-autonomous 2D cut-out / rig animation, with AI-generated character assets, feature-film coverage, and a separate mouth/lip-sync layer.

## Executive Summary

For this project, a character package should be treated as a **reusable animation grammar**, not as a bag of every possible drawing. A feature film needs enough material to compose believable shots, but not so much that every pose becomes a unique one-off. The right package granularity is therefore:

1. **Identity / bible assets** — master references, turnarounds, costume rules, and style anchors.
2. **Rig assets** — reusable body parts, head parts, costume layers, and attachment points.
3. **Performance assets** — expressions, visemes, hands, props, and high-value poses.
4. **Shot augmentation assets** — AI-assisted start/end frames or difficult motion inserts for scenes that the rig system cannot cover cleanly.

The evidence from current rigging systems points the same way: 2D cut-out rigs work best when the model is built from **separable layers**, **peg/deformer hierarchies**, **multi-pose chains**, and **narrowly scoped mouth and face libraries** rather than a single monolithic image. Official Harmony and Adobe Character Animator docs both encourage structured body-feature naming, turner views, viseme libraries, and layered rig hierarchy rather than per-shot image explosion.

## Research Sources and What They Imply

### Toon Boom Harmony documentation
Relevant Harmony docs describe:

- **Rigging drawings to deformers** with kinematic outputs so hands, heads, and other parts can follow deformers without being ruined by the deformation itself.
- **Pegs above deformers** as the safer hierarchy for offsets.
- **Multi-pose rigs** as a chain system where additional deformation chains are created for additional poses.

That implies our package should store enough structural data to support a character as a set of reusable part families and pose families, not just flattened illustration frames.

Sources:
- https://docs.toonboom.com/help/harmony-21/premium/deformation/about-rigging-with-deformers.html
- https://docs.toonboom.com/help/harmony-20/essentials/deformation/rig-kinematic-output.html
- https://docs.toonboom.com/help/harmony-24/premium/deformation/create-main-deformation-chain-multi-pose-rig.html
- https://docs.toonboom.com/help/harmony-24/premium/deformation/create-additional-deformation-chain-multi-pose-rig.html

### Adobe Character Animator / Adobe Animate documentation
Adobe’s prep-artwork docs explicitly organize head and body art into named features such as frontal, left quarter, right quarter, profile, mouth, eyes, brows, jaw, and visemes. Adobe Animate’s lip-sync docs also show that mouth shapes can be stored and mapped as a discrete mouth system.

That implies the mouth engine should be **its own layer on top of the body rig**, with per-angle viseme artwork or mappings, rather than a single generic mouth bank.

Sources:
- https://helpx.adobe.com/lv/adobe-character-animator/using/prepare-artwork.html
- https://helpx.adobe.com/fi/adobe-character-animator/using/behaviors/body-directly-controlled.html
- https://helpx.adobe.com/lv/animate/using/symbol-instances.html
- https://helpx.adobe.com/lt/animate/how-to/auto-lip-sync-sensei.html

### Live2D Cubism documentation
Live2D’s official material reinforces the same broader principle: 2D character systems gain flexibility from carefully organized parts, parameters, and layer structure rather than from isolated full illustrations.

Source:
- https://docs.live2d.com/

### Current project baseline
The current Animate package model already points in the right direction. The current `CharacterPackageManifest` has:

- package metadata
- defaults
- assets
- generation blueprints

and assets already support:

- role
- name
- part type
- angle
- pose
- placement metadata
- tags
- notes

The current sample Luke package is a proof-of-concept that includes references, base poses, turnaround anchors, hero poses, and a few full-canvas part overlays. That is enough to prove the mechanism, but not enough for a feature film.

Current code references:
- `Packages/Animate/SampleData/CharacterPackages/LukePainterlyV1/character-package.json`
- `Packages/Animate/Sources/AnimateUI/Models/CharacterPackageModels.swift`

## Recommended Package Principle

### 1. Package by reusable function, not by shot
A shot is a consumer of assets. A package is a library of assets.

### 2. Separate identity from wardrobe
A character identity should be stable. Costumes should be swappable variants.

### 3. Keep the mouth engine separate
Lip-sync needs its own asset family because mouth shapes are angle-sensitive and timing-sensitive.

### 4. Prefer semantic groups over microscopic parts
Do not split a package into hundreds of tiny fragments unless each fragment genuinely needs independent motion or replacement.

### 5. Build for reuse and regeneration
The package should remember what was approved, what was derived, what references were used, and what can be regenerated later.

## Asset Taxonomy

Below is the asset taxonomy I recommend for this project.

### A. Identity / Bible Assets
These are the foundation and should exist for every main character:

- Main reference photo(s)
- Style reference sheet(s)
- Master sheet(s)
- Costume bible sheet(s)
- Approved palette references
- Approved silhouette references
- Full-body turnaround sheet
- Head turnaround sheet

These assets are not just for rendering; they are the authoritative visual contract for the character.

### B. Rig / Anatomy Assets
These are the pieces that drive body animation:

- Head
- Face
- Hair front / hair back
- Neck
- Torso / chest
- Hips / pelvis
- Upper arms / forearms / hands
- Thighs / calves / feet
- Shoulder overlays
- Clothing panels that bend independently

For feature-film use, you want parts that support believable motion, not necessarily every anatomical sub-piece. A head, torso, upper-limb, lower-limb, and hand system is the important baseline.

### C. Face Performance Assets
These support acting and speech:

- Eye states
- Eyelids / blinks
- Eyebrows
- Mouth rest
- Expression set
- Viseme set
- Jaw / chin variants when needed

This is the set that gives the character emotional readability.

### D. Costume / Wardrobe Assets
For a long-form show, wardrobe must be modular:

- Base outfit
- Soldier / civilian outfit variants
- Shirts / jackets / coats
- Pants / shorts / skirts
- Boots / shoes
- Straps / belts / satchels
- Scarves / wraps
- Accessories that must travel with the character

Wardrobe should not be embedded as one flat costume image if it can instead be layered and swapped.

### E. Hands / Props / Interaction Assets
These are critical for believability:

- Open hand
- Relaxed hand
- Pointing hand
- Grasping hand
- Pinch / pinch-like gesture
- Fist
- Two-handed hold
- Prop variants for common objects

Props should be separate because they often need their own placement rules and replacement behavior.

### F. Hero / Pose Assets
These are shot anchors and reusable motion seeds:

- Neutral standing
- Walking
- Reaching
- Kneeling
- Sitting
- Pointing
- Carrying / holding
- Dialogue stance

These should be limited and strategic. They are not substitutes for the rig; they are high-value anchors.

## Minimal vs Production-Grade Package

### Minimal package for a usable character
A minimal production-ready package should usually include:

- 1 master identity reference sheet
- 1 head turnaround sheet
- 1 full-body turnaround sheet
- 1 neutral rig-ready base pose
- 8–12 expression assets
- 10–14 viseme assets
- 4–8 hand poses
- 1 or 2 key costume variants
- 2–6 hero action poses
- core prop overlays if the character regularly uses them

This is enough to start animating scenes with a controlled look.

### Production-grade package for a feature film
For a feature, I would expect the package to expand into:

- multiple wardrobe states per main character
- more head-angle coverage
- better face/eye sub-structure
- more hand coverage
- more prop-specific overlays
- alternate base poses for posture shifts
- more robust mouth sets
- shot-specific AI augmentation when the rig cannot solve a scene cleanly

The important point is that production-grade does **not** mean “every possible pose is a unique asset.” It means the package can cover the film’s recurring needs without falling apart.

## Angle Coverage Strategy

The current app already uses an angle vocabulary like:

- front
- threeQuarterFront
- side
- threeQuarterBack
- back

That is a practical baseline, but for a feature film I recommend thinking in two parallel layers:

### Head / face angles
- front
- quarter left
- profile left
- quarter right
- profile right
- back of head

### Full-body angles
- front
- quarter left
- profile left
- quarter right
- profile right
- back

Not every part needs every angle. The package should identify which parts are angle-specific and which can be reused.

### Practical rule
- **Head and mouth assets** need the most angle specificity.
- **Torso and clothing** need moderate angle specificity.
- **Hands and props** need only the angles required by the script.

### When to create more angle coverage
Create extra angle coverage only when the character is frequently used in a way that exposes the angle:

- close conversational staging
- profile-heavy blocking
- frequent turns
- singing close-ups
- dramatic over-the-shoulder scenes

## Costume Layer Strategy

Costumes should be their own structured layer family.

### Recommended costume hierarchy
1. Base body / skin / underlying anatomy
2. Hair
3. Undershirt / base clothing
4. Outer garments
5. Straps / belts / satchels / bags
6. Props attached to the body
7. Surface overlays such as wear, dust, patches, insignia

### Why this matters
If a character is in both soldier and civilian wardrobes, the system should not duplicate the entire character. It should reuse the same identity and body rig, then swap wardrobe groups and accessory families.

### Costume packages should include
- wardrobe-specific reference sheet
- wardrobe-specific full-body poses
- wardrobe-specific hand / prop coverage
- wardrobe-specific accessory rules

That lets Luke, Amira, or any other character have a soldier package and a civilian package without becoming two unrelated characters.

## Hands and Props

Hands are often the most under-specified part of a rig package, but they matter a lot for feature animation.

### Minimum hand set
- open
- relaxed
- pointing
- holding / grasping
- closed/fist
- two-handed hold
- side-facing support hand

### Prop rules
Every recurring prop should know:
- what hand it belongs in
- its anchor point
- whether it rotates with the wrist or independently
- whether it should be its own overlay or a separate subpackage

### Recommendation
Treat props as first-class package assets, not as afterthoughts. A satchel, medical kit, phone, rifle, notebook, or tool can all be reusable assets that the animation engine needs to place correctly.

## Reuse Strategy

The most important design idea is this:

> **One package should be the canonical reference spine for a character, and everything else should derive from it.**

### Recommended reuse tiers

#### Tier 1 — Canonical references
- master sheet
- head sheet
- full-body sheet
- costume bible sheet

#### Tier 2 — Canonical rig assets
- base pose
- reusable body parts
- face parts
- hands
- costume overlays

#### Tier 3 — Derived performance assets
- expressions
- visemes
- hero poses
- scene-specific pose variants

#### Tier 4 — Shot-specific augmentation
- AI video start/end frames
- difficult motion inserts
- rare camera moves

### What not to do
- Do not generate every frame as a unique asset.
- Do not treat each shot as a new character package.
- Do not over-fragment the character into too many subparts that are impossible to maintain.

## Mouth / Lip-Sync Engine Architecture

I agree with the intuition that the mouth system should be a separate engine layer.

### Why separate it
The mouth system has its own:
- timing logic
- transcript/lyric alignment
- viseme selection
- angle-awareness
- face-anchor tracking

If it is folded into the main animation engine too early, the system becomes harder to debug and harder to improve.

### Recommended mouth engine responsibilities
- Parse lyrics or dialogue text
- Align text with timing cues
- Map phonetic units to visemes
- Choose angle-appropriate mouth shapes
- Preserve mouth anchor position across turns
- Blend or swap mouth assets with confidence values

### Mouth asset model
The mouth engine should support:
- a rest mouth
- core visemes
- optional expressive mouth shapes
- angle-specific mouth banks

### Important insight
Adobe’s Character Animator docs show the same concept: mouth shapes and visemes are a dedicated system, and quarter/profile views can follow the same general approach as the frontal mouth setup. That supports a **per-angle viseme atlas** rather than a single universal mouth sheet.

### Practical output model
A good mouth engine may output:
- `visemeID`
- `confidence`
- `mouthOpenAmount`
- `mouthAnchorPoint`
- `headAngleBucket`
- `sourceTimeRange`

That gives the visual layer enough information to choose the right mouth asset or blend.

## Proposed Package Manifest Schema for This Project

The current manifest schema is already a good start, but for the film workflow I recommend extending it into a more expressive `schemaVersion: 3` structure.

### Current baseline
The existing manifest already carries:
- package metadata
- defaults
- assets
- blueprints

and assets already carry:
- role
- name
- partType
- angle
- pose
- placement
- tags
- notes

### Proposed additions
Add fields that make the package self-describing for animation and regeneration:

```json
{
  "schemaVersion": 3,
  "id": "...",
  "slug": "luke-hart-soldier-v1",
  "displayName": "Luke Hart — Soldier",
  "character": {
    "displayName": "Luke Hart",
    "sourceSlug": "luke",
    "storageSlug": "luke-hart",
    "wardrobeKey": "soldier",
    "age": 24,
    "gender": "male",
    "role": "lead"
  },
  "style": {
    "name": "grounded-anime-2d",
    "paletteTags": ["desert", "dust", "muted", "dramatic"],
    "lineStyle": "clean-ink",
    "renderIntent": "feature-film-rig"
  },
  "coverage": {
    "angles": ["front", "quarterLeft", "profileLeft", "quarterRight", "profileRight", "back"],
    "poses": ["neutral", "walking", "reaching", "kneeling", "pointing"],
    "expressions": ["neutral", "happy", "sad", "angry", "worried"],
    "visemes": ["rest", "AI", "E", "O", "U", "MBP", "FV", "L", "WQ"]
  },
  "libraries": {
    "head": {
      "masterSheetAssetIDs": ["..."],
      "turnaroundAssetIDs": ["..."],
      "expressionAssetIDs": ["..."]
    },
    "body": {
      "basePoseAssetIDs": ["..."],
      "poseAssetIDs": ["..."],
      "partAssetIDs": ["..."]
    },
    "mouth": {
      "atlasByAngle": {
        "front": ["..."],
        "quarterLeft": ["..."],
        "profileLeft": ["..."]
      }
    },
    "hands": {
      "open": ["..."],
      "relaxed": ["..."],
      "grasp": ["..."]
    },
    "props": {
      "satchel": ["..."],
      "medicalKit": ["..."]
    }
  },
  "assets": [
    {
      "id": "...",
      "role": "reference",
      "name": "Luke Main Reference",
      "partType": null,
      "angle": "front",
      "pose": "neutral",
      "placement": null,
      "relativePath": "references/luke-main.png",
      "tags": ["identity", "master"],
      "notes": "Primary identity anchor"
    }
  ],
  "blueprints": [
    {
      "id": "...",
      "name": "Generate Soldier Turnaround",
      "prompt": "...",
      "negativePrompt": "...",
      "referenceAssetIDs": ["..."],
      "outputSpecs": [
        { "role": "turnaround", "angle": "front", "pose": "neutral" }
      ],
      "canvasSize": { "width": 4096, "height": 4096 },
      "seed": 12345,
      "tags": ["generate", "turnaround"]
    }
  ],
  "provenance": {
    "generatedBy": "Nano Banana 2",
    "approvedFrom": ["..."],
    "sourceRefs": ["..."],
    "notes": "..."
  }
}
```

### Why these additions matter
- `character.sourceSlug` and `character.storageSlug` let us separate source identity from on-disk storage.
- `coverage` tells the generator what the package actually supports.
- `libraries` makes it easier for the runtime to know which sub-assets are the canonical ones.
- `provenance` makes AI-generated assets auditable and reversible.

## Concrete Recommendation for This Project

### For each main character, build three linked package families:

1. **Identity package**
   - master reference sheet
   - head turn sheet
   - full-body turn sheet
   - costume bible

2. **Rig package**
   - body parts
   - face parts
   - hands
   - props
   - layered costume elements

3. **Performance package**
   - expressions
   - visemes
   - hero poses
   - scene-specific action poses

### Then allow a fourth optional family:
4. **Augmentation package**
   - AI video start/end frames
   - difficult motion examples
   - rare cinematic shots

That structure is likely the best compromise between:
- film-level consistency
- future regeneration
- manageable complexity
- AI-assisted asset generation

## Final Conclusion

For this kind of semi-autonomous 2D animation pipeline, the winning strategy is **not** to create an ever-growing pile of unique images. The winning strategy is to create a **small number of canonical reference packages**, then attach progressively more specialized asset families underneath them.

If we get the taxonomy right, the mouth engine separate, the wardrobe logic modular, and the manifest expressive enough, we can support a large feature with AI-assisted generation while still keeping the rig system sane.

## Sources

### Official / primary
- Toon Boom Harmony deformation and rigging docs:
  - https://docs.toonboom.com/help/harmony-21/premium/deformation/about-rigging-with-deformers.html
  - https://docs.toonboom.com/help/harmony-20/essentials/deformation/rig-kinematic-output.html
  - https://docs.toonboom.com/help/harmony-24/premium/deformation/create-main-deformation-chain-multi-pose-rig.html
  - https://docs.toonboom.com/help/harmony-24/premium/deformation/create-additional-deformation-chain-multi-pose-rig.html
- Adobe Character Animator artwork preparation:
  - https://helpx.adobe.com/lv/adobe-character-animator/using/prepare-artwork.html
  - https://helpx.adobe.com/fi/adobe-character-animator/using/behaviors/body-directly-controlled.html
- Adobe Animate lip-sync docs:
  - https://helpx.adobe.com/lv/animate/using/symbol-instances.html
  - https://helpx.adobe.com/lt/animate/how-to/auto-lip-sync-sensei.html

### Project baseline
- `Packages/Animate/SampleData/CharacterPackages/LukePainterlyV1/character-package.json`
- `Packages/Animate/Sources/AnimateUI/Models/CharacterPackageModels.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
