# 03 — Data Contracts

All contracts should be versioned and Codable. Unknown optional fields should not crash decoding. Required identity fields should fail validation when missing.

## `TranscriptImport`

```json
{
  "version": 1,
  "runID": "UUID",
  "createdAt": "ISO-8601",
  "source": {
    "kind": "speech_to_text | pasted_text | file",
    "path": "optional local path",
    "language": "en",
    "durationSeconds": null
  },
  "rawTranscriptPath": "Metadata/automation/transcript-imports/<run>/raw-transcript.txt",
  "cleanedTranscriptPath": "Metadata/automation/transcript-imports/<run>/cleaned-transcript.txt",
  "segments": [
    {
      "segmentID": "seg-001",
      "startOffsetSeconds": null,
      "endOffsetSeconds": null,
      "text": "The convoy enters the valley at dawn..."
    }
  ]
}
```

## `TranscriptShotSpec`

Minimum useful LLM output from dictated text:

```json
{
  "version": 1,
  "runID": "UUID",
  "sceneKey": "Songs/1.01.0 - Overture.ows",
  "shotKey": "overture-valley-choke-points-establish",
  "proposedShotID": "optional UUID",
  "shotName": "Valley choke points establish",
  "sourceTextExcerpt": "A single road cuts through the valley floor...",
  "charactersPresent": [],
  "focusCharacterSlug": null,
  "place": {
    "kind": "known_place | proposed_new_place | ambiguous",
    "placeID": "990DFFC1-FEA5-59F5-A3BC-212DEF39734A",
    "placeName": "Mountain Valley Approach Road",
    "confidence": 0.94
  },
  "timeOfDay": {
    "value": "dawn",
    "confidence": 0.88,
    "source": "explicit"
  },
  "camera": {
    "cameraShot": "extreme_wide",
    "cameraMovement": "slow_track_forward",
    "lensFamily": "medium telephoto or grounded documentary",
    "screenDirection": "convoy moves upstream/right-to-left if established"
  },
  "shotIntent": "establishing",
  "visualAction": "The convoy follows the dusty road along the river as peaks catch first light.",
  "startFrameDescription": "Wide dawn view of valley road, river low below, bridge and village legible.",
  "endFrameDescription": "Convoy has advanced farther along the road toward the ridge approach.",
  "continuityLocks": [
    "early-2000s period",
    "river low in valley",
    "village on north bank only",
    "old stone bridge as only crossing",
    "small temporary ridge base"
  ],
  "referenceNeeds": [
    "location_identity",
    "spatial_map",
    "style"
  ],
  "ambiguities": [],
  "manualOverrideHints": []
}
```

## `EffectiveShotSpec`

Compiled truth used for reference resolution and prompt planning:

```json
{
  "version": 1,
  "sceneID": "scene UUID or stable scene key",
  "shotID": "AnimationSceneShot UUID",
  "owsSongPath": "Songs/1.01.0 - Overture.ows",
  "shotName": "Valley choke points establish",
  "source": {
    "kind": "existing_scene_shot | transcript_import | merged",
    "sourceLineNumber": 7,
    "sourceLyricExcerpt": "A single road cuts through the valley floor...",
    "sourceTextExcerpt": "..."
  },
  "place": {
    "placeID": "990DFFC1-FEA5-59F5-A3BC-212DEF39734A",
    "placeName": "Mountain Valley Approach Road",
    "locationCategory": "Exterior",
    "approvedImagePath": "Animate/backgrounds/places/...",
    "canonicalWorldContextPath": "Places/places-world-context.json"
  },
  "characters": [
    {
      "slug": "johnny-ward",
      "id": "9012E260-9F82-4C5D-895D-0775F76BB807",
      "roleInShot": "focus | present | background",
      "wardrobeType": "soldier"
    }
  ],
  "camera": {
    "cameraShot": "wide",
    "cameraMovement": "hold",
    "shotIntent": "movement"
  },
  "visualAction": "What physically changes during the shot.",
  "startFrameDescription": "Opening visible state.",
  "endFrameDescription": "Closing visible state.",
  "worldContinuity": {
    "timePeriod": "Early 2000s",
    "regionalWorld": "Persian-Afghan highland valley",
    "technologyGuardrails": "No future technology; sparse early-mobile-era details only"
  },
  "continuityLocks": [
    "character likeness",
    "wardrobe",
    "place geography",
    "lighting",
    "screen direction"
  ],
  "manualOverrides": [],
  "validation": {
    "status": "valid | blocked | needs_review",
    "errors": [],
    "warnings": []
  }
}
```

## `ReferenceContract`

```json
{
  "version": 1,
  "sceneID": "...",
  "shotID": "...",
  "resolverVersion": "reference-contract-resolver-1",
  "createdAt": "ISO-8601",
  "effectiveShotSpecHash": "sha256",
  "maxReferenceCount": 8,
  "requiredRoles": [
    "location_identity",
    "spatial_map",
    "character_identity",
    "character_costume",
    "style"
  ],
  "selectedReferences": [
    {
      "referenceID": "ref-001",
      "path": "/absolute/path/to/image.png",
      "relativePath": "Animate/backgrounds/...",
      "role": "location_identity",
      "ownerType": "place",
      "ownerID": "990DFFC1-FEA5-59F5-A3BC-212DEF39734A",
      "score": 1.0,
      "reason": "Approved image for scene backgroundID",
      "pinned": false,
      "excluded": false,
      "source": "place.approvedImagePath"
    }
  ],
  "rejectedReferences": [
    {
      "path": "/absolute/bad-ref.png",
      "reason": "Wrong bridge angle"
    }
  ],
  "missingRoles": [],
  "conflicts": [],
  "manualOverrides": []
}
```

## `ShotFrameGenerationPlan`

```json
{
  "version": 1,
  "sceneID": "...",
  "shotID": "...",
  "effectiveShotSpecPath": "Animate/shot-specs/<scene>/<shot>.json",
  "referenceContractPath": "Animate/reference-contracts/<scene>/<shot>.json",
  "moments": [
    {
      "moment": "beginning",
      "mode": "generate",
      "sourceImagePath": null,
      "prompt": {
        "positive": "A grounded early-2000s Persian-Afghan highland valley...",
        "negative": "No modern city, no drones, no glossy CGI...",
        "motionIntent": "Convoy begins entering the frame along the road."
      },
      "referenceIDs": ["ref-001", "ref-002"],
      "approvalRequired": true
    },
    {
      "moment": "end",
      "mode": "edit",
      "sourceImagePath": "Animate/generated-frames/.../beginning/variant-001.png",
      "prompt": {
        "positive": "Keep the same valley geography and convoy identity, advance the convoy...",
        "negative": "Do not change bridge placement or village side of river.",
        "motionIntent": "Convoy has moved farther along the same road."
      },
      "referenceIDs": ["ref-001", "ref-002"],
      "approvalRequired": true
    }
  ],
  "openMatte": {
    "enabled": true,
    "generatedAspectRatio": "4:3",
    "targetAspectRatio": "16:9",
    "cropMotion": "hold"
  },
  "costEstimate": {
    "imageJobs": 2,
    "videoJobs": 0
  },
  "status": "dry_run | ready | generating | complete | blocked"
}
```

## `GeneratedFrameRecord`

```json
{
  "version": 1,
  "sceneID": "...",
  "shotID": "...",
  "moment": "beginning | middle | end",
  "variantID": "variant-001",
  "provider": "gemini_vertex",
  "mode": "generate | edit",
  "sourceImagePath": null,
  "outputImagePath": "Animate/generated-frames/<scene>/<shot>/beginning/variant-001.png",
  "promptPath": "prompt.txt",
  "responsePath": "response.txt",
  "planPath": "plan.json",
  "referenceContractPath": "Animate/reference-contracts/<scene>/<shot>.reference-contract.json",
  "approved": false,
  "approvedAt": null,
  "qaPath": null,
  "status": "queued | generating | succeeded | failed | approved | rejected"
}
```

## `VideoTaskRecord`

```json
{
  "version": 1,
  "shotID": "...",
  "sceneID": "...",
  "provider": "vidu",
  "providerModel": "vidu2.0",
  "startFramePath": "/absolute/start.png",
  "endFramePath": "/absolute/end.png",
  "startFramePublicURL": "https://...",
  "endFramePublicURL": "https://...",
  "motionPrompt": "clear physical motion between start and end",
  "durationSeconds": 4,
  "resolution": "1080p",
  "movementAmplitude": "auto",
  "taskID": "provider-task-id",
  "status": "queued | generating | succeeded | failed",
  "outputPath": "/absolute/output.mp4",
  "qaStatus": "untested | pass | fail | needs_review",
  "attempt": 1
}
```

## `QAResult`

```json
{
  "version": 1,
  "sceneID": "...",
  "shotID": "...",
  "artifactKind": "frame | video",
  "artifactPath": "/absolute/path",
  "status": "pass | fail | needs_review",
  "checks": [
    {
      "name": "place_identity",
      "status": "pass | fail | warning",
      "evidence": "The old stone bridge and north-bank village are visible.",
      "correctionHint": null
    }
  ],
  "retryRecommendation": {
    "action": "accept | regenerate | edit | manual_review",
    "reason": "Wrong place geography.",
    "correctionPrompt": "Keep the approved valley map and bridge placement..."
  },
  "attempt": 1,
  "createdAt": "ISO-8601"
}
```

## Validation rules

1. Every shot must resolve to exactly one known place or one explicit `new_place_candidate`.
2. Character slugs must match `Characters/*/rig.json` or become `new_character_candidate`.
3. A shot cannot queue video until approved start/end frames exist.
4. A known place/character shot cannot use a generic prompt without references.
5. New geography must not be silently mapped to a nearby existing place.
6. Storyboard/manual anchors outrank LLM text.
7. Manual pinned refs must survive resolver re-runs.
8. Rejected refs must not be auto-selected again.
9. World period must come from `Places/places-world-context.json`.
10. Prompts must spell out world, period, materials, lighting, and tone.
