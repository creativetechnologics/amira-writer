# Scenes Imagine Triplet Prompt Contract

Date: 2026-04-21
Workspace: `/Volumes/Programming/Amira Writer`

## Purpose

Document the prompt contract for the **Scenes** tab shot-image workflow.

This is distinct from the Animate shot-production strip.

- **Scenes imagine** = `beginningPrompt` / `middlePrompt` / `endPrompt`
- **Animate shot production** = `firstFramePrompt` / `lastFramePrompt` / `motionDirection`

## Contract

Each Scenes shot prompt triplet represents three static stills from the **same shot**:

- Beginning = opening readable state
- Middle = peak readable state
- End = resolved readable state

All three must preserve:

- same camera
- same lens feel
- same framing family
- same screen direction
- same geography
- same lighting continuity
- same visible character identity / wardrobe / prop logic

Only the visible in-frame beat should progress.

## Persistence

The app stores Scenes prompt triplets in the project gallery index:

- `<project>/Scenes/imagine/galleries.json`

The app scans image files from:

- `<project>/Scenes/imagine/scenes/<scene-slug>/shot-###/{beginning,middle,end}/`

As of this update, gallery refresh merges scanned image paths with stored prompt text and selected-image state instead of replacing the whole record.

## Integration points

- `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift`
  - prompt generation rules
  - companion prompt continuity anchors
- `Packages/Animate/Sources/AnimateUI/Views/ImagineScenesPageView.swift`
  - prompt editor loads/saves the current moment prompt
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
  - prompt accessors and refresh merge logic
- `Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift`
  - gallery prompt helpers
