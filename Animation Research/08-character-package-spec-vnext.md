# 08 — Character Package Spec vNext

Date: 2026-03-30

## Purpose
Define the next-generation package contract for Amira Writer so that a character package contains enough information to support semi-autonomous 2D animation, a separate mouth engine, costume swapping, accessory handling, and future AI-assisted asset generation.

This is a **proposed spec**, not an implemented one.

---

## 1. Design goals

The spec must support:
- reusable runtime assembly
- deterministic animation playback
- AI-assisted asset generation and regeneration
- costume and accessory swapping
- angle-aware mouth playback
- motion primitives instead of one-off per-shot art
- explicit QA / approval state

---

## 2. Current manifest vs proposed manifest

The current manifest already has strong foundations:
- metadata
- defaults
- assets
- generation blueprints

The next version should keep those, but add richer grouping and runtime metadata.

### Keep
- package metadata
- defaults
- per-asset role / angle / pose / placement
- generation blueprints

### Add
- identity profile
- costume packs
- accessory packs
- mouth profiles
- rig maps
- motion primitive definitions
- compatibility matrices
- approval metadata
- anchor/attachment metadata
- asset-family grouping

---

## 3. Proposed top-level structure

```json
{
  "schemaVersion": 3,
  "id": "uuid",
  "slug": "luke-hart-hero-v1",
  "displayName": "Luke Hart Hero v1",
  "characterIdentity": { ... },
  "defaults": { ... },
  "assetFamilies": { ... },
  "costumePacks": [ ... ],
  "accessoryPacks": [ ... ],
  "mouthProfiles": [ ... ],
  "motionPrimitives": [ ... ],
  "placementMaps": [ ... ],
  "generationBlueprints": [ ... ],
  "qa": { ... }
}
```

---

## 4. characterIdentity

This is the immutable visual contract of the character.

```json
"characterIdentity": {
  "name": "Luke Hart",
  "characterType": "hero",
  "ageBand": "adult",
  "genderPresentation": "male",
  "styleProfile": "inked-gouache-drama",
  "identityReferences": ["asset-id-1", "asset-id-2"],
  "masterSheetAssetID": "asset-id-master-sheet",
  "headSheetAssetID": "asset-id-head-sheet",
  "paletteReferenceAssetIDs": ["asset-id-palette-1"],
  "notes": "Grounded early-2000s Afghanistan-war dramatic style."
}
```

---

## 5. assetFamilies

Group assets by function instead of one giant flat bag.

```json
"assetFamilies": {
  "references": [ ... ],
  "sheets": [ ... ],
  "rigParts": [ ... ],
  "expressions": [ ... ],
  "hands": [ ... ],
  "poses": [ ... ],
  "props": [ ... ],
  "heroFrames": [ ... ]
}
```

### Key point
The current flat `assets` list can still exist internally, but the manifest should expose **semantic families** so the runtime and tooling know what each cluster is for.

---

## 6. Rig part records

Each rig part should include:
- part type
- angle family
- pose compatibility
- placement
- pivot
- layer order
- deformability
- compatible costumes

```json
{
  "id": "asset-head-front",
  "family": "rigParts",
  "role": "rigPart",
  "partType": "head",
  "angle": "front",
  "pose": "neutral",
  "relativePath": "rig/head/front/head-front.png",
  "placement": {
    "normalizedCenter": { "x": 0.5, "y": 0.33 },
    "normalizedPivot": { "x": 0.5, "y": 0.72 },
    "normalizedSize": { "width": 0.34, "height": 0.28 },
    "mode": "framed"
  },
  "zOrder": 40,
  "compatibleCostumes": ["military-default", "civilian-default"],
  "tags": ["approved", "front", "neutral"]
}
```

---

## 7. Costume packs

Costumes should not duplicate the whole character.
They should override or augment the base rig.

```json
{
  "id": "military-default",
  "name": "Military / Medic",
  "sheetAssetID": "asset-sheet-military",
  "overlayAssetIDs": ["asset-jacket-front", "asset-trousers-front"],
  "propDefaults": ["medic-satchel"],
  "compatiblePoses": ["idle-neutral", "walk-a", "walk-b", "reach-satchel"],
  "notes": "Primary first-half-of-story uniform."
}
```

Recommended minimum: at least one major costume pack per narrative era.

---

## 8. Accessory packs

Accessories need their own pack structure because props change attachment logic.

```json
{
  "id": "medic-satchel",
  "name": "Medic Satchel",
  "attachmentPoint": "torso-right-strap",
  "assetIDs": ["satchel-front", "satchel-quarter-left", "satchel-side"],
  "swingBehavior": "secondary-follow",
  "notes": "Default Luke field accessory."
}
```

---

## 9. Mouth profiles

This is the big missing category in most simplistic rigs.

A mouth profile should include:
- angle family
- viseme set
- registration anchors
- jaw/open curves if supported
- fallback angle relationships

```json
{
  "id": "mouth-front-v1",
  "angleFamily": "front",
  "restAssetID": "mouth-front-rest",
  "visemeAssetMap": {
    "rest": "mouth-front-rest",
    "ai": "mouth-front-ai",
    "e": "mouth-front-e",
    "o": "mouth-front-o",
    "u": "mouth-front-u",
    "consonant": "mouth-front-consonant",
    "fv": "mouth-front-fv",
    "l": "mouth-front-l",
    "mbp": "mouth-front-mbp",
    "wq": "mouth-front-wq"
  },
  "registration": {
    "anchorPoint": { "x": 0.5, "y": 0.62 },
    "safeBounds": { "width": 0.16, "height": 0.09 }
  },
  "fallbackAngleFamilies": ["quarter-left", "quarter-right"]
}
```

---

## 10. Motion primitives

A character package should include reusable motion primitives, not just images.

```json
{
  "id": "walk-neutral",
  "name": "Walk Neutral",
  "kind": "locomotion",
  "requiredAngles": ["front", "quarter-left", "quarter-right", "profile-left", "profile-right"],
  "requiredPoseAssets": ["walk-a", "walk-b", "walk-c", "walk-d"],
  "timingDefaults": {
    "fps": 24,
    "cycleFrames": 16
  },
  "runtimeHints": {
    "supportsSpeedScaling": true,
    "supportsPropCarry": true
  }
}
```

This makes the package directly useful to the motion engine.

---

## 11. QA metadata

Every asset family should have review state.

```json
"qa": {
  "status": "production-ready",
  "approvedBy": "Gary",
  "approvedAt": "2026-03-30T00:00:00Z",
  "coverage": {
    "headAngles": 0.9,
    "bodyAngles": 0.8,
    "costumes": 0.7,
    "mouthAngles": 0.6,
    "gestureCoverage": 0.5
  },
  "knownGaps": [
    "No right-profile singing mouth bank",
    "No kneeling civilian sheet yet"
  ]
}
```

---

## 12. Hero vs supporting vs background package tiers

### Hero
Needs:
- full identity set
- multiple costumes
- complete mouth profiles
- large gesture library
- robust motion primitive coverage

### Supporting
Needs:
- reduced motion library
- reduced costume coverage
- fewer corrective assets
- smaller mouth profile set

### Background
Needs:
- very small sheet set
- low gesture complexity
- maybe no full mouth engine at all
- often AI-video or crowd fallback

---

## 13. What should be implemented first

The first implementation target should not be the whole spec.
It should be:

1. identity
2. sheets
3. mouth profiles
4. costume packs
5. motion primitives

That sequence creates the most immediate runtime leverage.
