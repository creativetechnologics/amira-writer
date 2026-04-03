# Animation Handoff April One

Date: April 1, 2026
Project: Amira Writer

## Current Focus

This handoff is for the animation work inside `Packages/Animate`, especially the 2D Animate page and the emerging long-term hybrid 2D/3D direction.

## What Was Fixed / Changed

### 1) 2D preview is no longer black

The old embedded preview path was unreliable in-app even when offscreen renders were valid.

Current approach:
- single preview pane
- SwiftUI image-backed preview
- uses the existing offscreen snapshot renderer

Important result:
- the preview is now visible in-app

Key files:
- `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/CanvasView.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimationPreviewSnapshotExporter.swift`

### 2) Preview scaling was stabilized

The preview was warping placements/sizes because it was effectively rendering against the live pane size.

Current behavior:
- render at the project’s canonical Animate resolution from `animate.json`
- then scale the finished frame to fit the 21:9 preview container

This keeps scene placement more stable.

### 3) Timeline pane is now explicitly resizable

The preview/timeline split is no longer just a passive `VSplitView` expectation.

Implemented:
- explicit vertical split behavior
- persisted timeline height via app storage
- draggable divider

Key file:
- `Packages/ProjectKit/Sources/ProjectKit/OperaChrome.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift`

### 4) Initial shot timing editing is now surfaced

The safest first pass was **not** rewriting the Metal timeline editor.

Instead:
- selected shot timing is visible under the waveform strip
- authored shot edges can be trimmed in the scene-local timeline area
- Metal timeline playhead now drags continuously

Important limitation:
- this is still an early pass
- `TimelineEditorView` is not yet a full After Effects-style clip editor

Key files:
- `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/TimelineView.swift`

### 5) Inspector was reorganized

Top-level inspector tabs are now:
- `Assets`
- `Properties`
- `LLM`

Assets tab now emphasizes:
- current scene asset inventory
- direction/libretto-derived asset requirements

Key file:
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

## Silver Scene Status

`1.05.0 Silver` now has generated placeholder scene data and renderable content.

Important nuance:
- the data/assets existed before the final preview rescue
- the main blocking issue was the in-app preview path, not missing scene content

## Files Most Relevant For Claude

### Core 2D Animate UI
- `Packages/Animate/Sources/AnimateUI/Views/AnimatePageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/TimelineView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/CanvasView.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimationPreviewSnapshotExporter.swift`

### Asset / direction inference
- `Packages/Animate/Sources/AnimateUI/Services/AnimateAssetRequirementsService.swift`

### Shared chrome / divider
- `Packages/ProjectKit/Sources/ProjectKit/OperaChrome.swift`

## Current Architecture Read

### Near-term reality

The 2D Animate page is becoming workable, but it is still not enough for:
- robust object interaction
- believable body nuance
- reliable attachments
- strong spatial consistency
- sophisticated camera/space logic

### Best long-term direction

The best long-term Amira animation architecture is:

> **3D scene/object/rig logic underneath, with 2D asset presentation on top**

Meaning:
- 3D backend for:
  - staging
  - object placement
  - attachments
  - spatial logic
  - camera
- 2D assets for:
  - stylized/anime presentation
  - angle packs
  - layered character art
  - cutout/body-part rendering

### What this means strategically

Do **not** bet the final system on pure 2D puppetry alone.

Pure Live2D/Spine-style approaches are useful references, but they are not the right final core for Amira’s full object/world interaction needs.

## Research Conclusion

As of April 1, 2026:

- strongest commercial mixed-workflow reference:
  - **Toon Boom Harmony Premium 25**
- useful but not ideal as Amira’s final core runtime:
  - **Live2D Cubism**
  - **Spine**
  - **Moho**

Reason:
- they are strong for 2D rigs
- weaker as the full answer to world/object-aware animated staging

## Recommended Next Steps

### Highest priority
1. Add **direct object selection in the 2D preview**
2. Add **inspector-driven keyframe editing per selected object**
3. Keep evolving the timeline toward a more **After Effects-like** lane/clip workflow

### Strategic next step
4. Continue building the path toward:
   - 3D scene/object backend
   - 2D asset presentation layer

## Build / Runtime Notes

Server build/install path:
- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Synced device copy:
- `~/Programming/!Applications/Amira Writer.app`

Do not assume the server app bundle is the actual device runtime path.

## Relevant Sources

- Toon Boom Harmony Premium: https://www.toonboom.com/products/harmony/premium
- Toon Boom Harmony: https://www.toonboom.com/products/harmony
- Live2D docs: https://docs.live2d.com/
- Live2D official: https://www.live2d.com/en/
- Spine official: https://esotericsoftware.com/
- Moho manual: https://www.lostmarble.com/manual/13.5/Moho%20Tutorial%20Manual.pdf
- Moho 3D scene tutorial: https://www.lostmarble.com/moho/manual/tut05/08/index.html
- Orange / TRIGUN STAMPEDE precedent: https://www.orange-cg.com/works/trigun-stampede/
