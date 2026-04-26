# 04 — Reference Mesh

## Purpose

The reference mesh should choose the right images for a shot automatically while preventing wrong-location, wrong-character, wrong-period, and wrong-style drift.

The resolver should produce a durable `ReferenceContract`, not just a list of images.

## Reference roles

| Role | Required when | Typical source |
|---|---|---|
| `location_identity` | Every known place shot | Place approved image |
| `spatial_map` | Outdoor/geography shots | Hand-curated map reference |
| `landmark_design` | Bridge/landmark shots | Registry bridge refs |
| `character_identity` | Character visible/focus | Master sheet/profile/head turnaround |
| `character_costume` | Character visible | Costume reference sets |
| `storyboard_layout` | Storyboard exists | iPad/storyboard frame |
| `shot_continuity` | Same scene/adjacent shot exists | Approved prior generated frames |
| `style` | Always, unless prompt-only style is enough | Animated look prompt/style refs |
| `manual_pinned` | User pins anything | Manual override |

## Resolver priority order

1. Manual pinned references.
2. Same-shot storyboard/layout references.
3. Same-shot approved generated frames.
4. Exact character/place references by ID.
5. Hand-curated registry references: map, bridge, costume.
6. Same scene/place/character approved/generated references.
7. Spatial character annotations.
8. Tag/metadata query matches.
9. Embedding similarity.
10. Style fallback references.

## Reference quotas

Do not let one category crowd out required identity anchors.

### Character-focus exterior shot

Max 8 refs:

| Slot | Role |
|---|---|
| 1 | Manual pinned, if any |
| 2 | Character identity/master sheet |
| 3 | Character head/expression or costume |
| 4 | Place approved image |
| 5 | Map reference |
| 6 | Landmark ref, if relevant |
| 7 | Storyboard or prior shot frame |
| 8 | Style/animated look or extra continuity ref |

### Place-only establishing shot

Max 8 refs:

| Slot | Role |
|---|---|
| 1 | Manual pinned, if any |
| 2 | Place approved image |
| 3 | Map reference |
| 4 | Landmark ref, if relevant |
| 5 | Same-place generated image |
| 6 | Storyboard/layout |
| 7 | Style ref |
| 8 | Optional adjacent-shot continuity ref |

### Interior character dialogue shot

Max 8 refs:

| Slot | Role |
|---|---|
| 1 | Manual pinned |
| 2 | Character A identity |
| 3 | Character A costume/head |
| 4 | Character B identity, if present |
| 5 | Character B costume/head |
| 6 | Interior place approved image |
| 7 | Storyboard/layout |
| 8 | Style ref |

## Drift prevention

| Drift risk | Prevention |
|---|---|
| Wrong character | Require exact slug match and character identity ref. |
| Wrong wardrobe | Include costume ref and wardrobe text. |
| Wrong place | Require known `placeID`; include approved place image. |
| Wrong geography | Add map ref for outdoor shots. |
| Wrong bridge | Add bridge design refs for bridge scenes. |
| Wrong time period | Inject canonical early-2000s world context. |
| Wrong style | Inject `Settings/animated-look-prompt.json`. |
| Wrong angle | Use storyboard/layout and prior approved frames. |
| Repeated bad refs | Persist rejection memory. |

## Outdoor/geography rule

Use map refs for:

- establishing shots
- bridge shots
- ridge/base shots
- market/village exterior shots
- shots where river/bridge/base/village relationships are visible
- any shot with geography continuity constraints

## Character rule

For character shots, use at least:

```text
character identity ref
+ costume/wardrobe ref
+ place ref
+ style/world context
```

For close-ups, prioritize face/head/expression. For wide shots, prioritize costume silhouette and place geography.

## Manual overrides

Manual overrides must be first-class data, not temporary UI choices.

Persist:

```json
{
  "pinnedReferences": [
    {
      "path": "/absolute/path.png",
      "role": "manual_pinned",
      "reason": "User wants this exact angle."
    }
  ],
  "rejectedReferences": [
    {
      "path": "/absolute/bad.png",
      "reason": "Wrong bridge profile."
    }
  ],
  "roleOverrides": [
    {
      "role": "spatial_map",
      "required": true
    }
  ]
}
```

## Conflict detection

Examples:

| Conflict | Report |
|---|---|
| Reference is day, shot says night | Warning: lighting mismatch. |
| Reference owner place differs from shot place | Block unless manually pinned. |
| Character ref slug differs from focus character | Block unless explicitly allowed. |
| Bridge ref selected for non-bridge interior | Warning or demote. |
| Storyboard says close-up, shot spec says wide | Needs review. |
