# 3D Animation Engine Handoff — April 2, 2026

## Session Summary

This session built out the entire 3D animation engine infrastructure for Amira Writer, from a basic SceneKit wireframe tool to a production-grade anime preview system.

## What Was Built (Deployed)

### Engine Core (New Files in `Packages/Animate/Sources/AnimateUI/Engine/`)

| File | Lines | What It Does |
|------|-------|-------------|
| `AnimationCameraSystem.swift` | 326 | Physical camera: focal length (mm), Super 35mm sensor, DOF with circle-of-confusion, dolly/crane/handheld rig, all CameraMovement types, Newton-Raphson easing |
| `CelShadingTechnique.swift` | 238 | SCNTechnique post-process: color quantization into N bands, ink line outlines. Configurable settings (outline width, color bands, thresholds) |
| `CelShading.metal` | 110 | Metal shader: color quantization + depth-based Sobel edge detection + color-contrast edges, full-screen quad compositing |
| `VariableFrameRateEngine.swift` | 234 | Spider-Verse style per-element frame rates: on ones/twos/threes/fours. Auto-hold selection from movement speed. Efficient skip-evaluation for preview |
| `SceneDepthManager.swift` | 173 | 5-layer anime depth system (far BG → foreground), parallax offsets, atmospheric tinting, DOF blur integration |
| `SceneProductionCompiler.swift` | 406 | Libretto directions → full 3D production plan: character blocking, camera choreography, object placement, depth assignments, frame rate profiles |
| `SceneAssetPipeline.swift` | 485 | Asset loading/caching: character 3D models (GLB/USDZ/OBJ), props, backgrounds. Scene assembly with depth layers |
| `ScenePreviewRenderer.swift` | 470 | Central coordinator: 3-point cinematic lighting, production plan loading, per-frame rendering with variable frame rates, camera interpolation |

### Earlier Session Work (Also Deployed)

| Change | File(s) |
|--------|---------|
| **3D Animate page** added as new mode | `Animate3DWorkspace.swift`, `OperaShellView.swift` |
| **Cast detection fix** (slug fallback) | `Animate3DSceneAdapter.swift`, `AnimateModels.swift`, `AnimateStore.swift` |
| **Character rendering** (mannequin with joints) | `Animate3DTestHarnessView.swift` via `Animate3DModelFactory.swift` |
| **Object placement fix** (ground-aligned, correct scale) | `Animate3DModels.swift`, `Animate3DSceneAdapter.swift`, `Animate3DTestHarnessView.swift` |
| **Secondary motion** (anticipation, follow-through, head lag) | `AnimationEngine.swift`, `Animate3DSceneAdapter.swift`, `Animate3DModels.swift` |
| **Camera smoothing** (shot transitions, procedural drift) | `Animate3DSceneAdapter.swift` |
| **Performance** (track cache, async motion trails, yielding) | `AnimateStore.swift`, `Animate3DSceneAdapter.swift`, `Animate3DTestHarnessView.swift` |
| **Playback fixed** (play button actually advances frames) | `Animate3DTestHarnessView.swift` |
| **Background rendering** (scene BG image in 3D view) | `Animate3DTestHarnessView.swift` |
| **12 bundled GLB models** (Kenney + Polygonal Mind) | `Resources/Models3D/` |
| **Props page** (new top-level mode) | `PropsWorkspace.swift`, `OperaShellView.swift` |
| **Characters 3D Models section** | `CharactersPageView.swift`, `AnimateModels.swift`, `AnimateStore.swift` |
| **Places grid + map overview** | `PlacesPageView.swift`, `AnimateModels.swift`, `AnimateStore.swift` |
| **Instant/Batch generation picker** | `GeminiGenerationPreflightSheet.swift`, workflows |
| **Batch queue inspector tab** | `InspectorView.swift`, `AnimateStore.swift` |
| **Show in Finder** on all character images | `CharactersPageView.swift`, `CharacterReferenceWorkflowSheet.swift` |
| **Tab bar fixed** (7 modes, no truncation) | `OperaShellView.swift` |
| **3D Animate merged** into Animate mode | `OperaShellView.swift` |
| **Apple Notes export/import** | `AppleNotesService.swift`, `ScriptInspectorView.swift` |
| **Inline reference workflow** | `CharactersPageView.swift`, `CharacterReferenceWorkflowSheet.swift` |
| **Header redesigned** (character name large) | `CharactersWorkspace.swift` |
| **Cursor jumping fixed** (debounced save) | `AnimateStore.swift` |
| **Prompt fixes** (white BG, no medic, no names) | `CharacterReferenceWorkflowModels.swift`, `CharacterLookDevelopmentModels.swift` |

## Architecture Overview

```
Libretto Text
    ↓
SceneDirectionParser (existing)
    ↓
SceneProductionCompiler (new) → SceneProductionPlan
    ↓                              ├─ CharacterBlockingPlan (positions, facing, acting beats)
    ↓                              ├─ CameraChoreographyPlan (focal length, movements, shot types)
    ↓                              ├─ ObjectPlacementPlan (world positions, depth layers)
    ↓                              └─ VariableFrameRateProfile (per-character hold styles)
    ↓
ScenePreviewRenderer (new)
    ├─ SceneAssetPipeline → loads GLB/USDZ models, backgrounds
    ├─ AnimationCameraSystem → focal length, DOF, rig (dolly/crane/handheld)
    ├─ VariableFrameRateEngine → per-element frame quantization
    ├─ SceneDepthManager → parallax, atmospheric tint, DOF blur
    └─ CelShadingTechnique → Metal post-process for anime look
         ↓
    SCNView (SceneKit renders to screen)
```

## What's NOT Wired Yet

The engine components exist as standalone files but are NOT yet connected to the existing Animate3DTestHarnessView. The integration points are:

1. **ScenePreviewRenderer needs to replace or supplement the existing Animate3DSceneView** — Currently the harness view builds its own SCNScene manually. The renderer has its own scene. These need to be unified.

2. **SceneProductionCompiler needs a trigger** — Something needs to call `compile()` when a scene is selected and feed the result to the renderer.

3. **CelShadingTechnique needs to be applied** — Call `CelShadingTechnique.apply(to: scnView, settings: ...)` after the SCNView is created.

4. **Depth Anything V2 (CoreML)** for background depth estimation — not yet integrated. Model is available at `apple/coreml-depth-anything-v2-small` on HuggingFace.

## Asset Formats

- **Character 3D models**: Export from Meshy.ai as **USDZ** (preferred, native SceneKit) or **GLB** (backup). Both work.
- **Background plates**: PNG or JPG, 1920x1080 or larger
- **Props**: GLB/USDZ/OBJ, stored in `Animate/objects/`
- **Character models go to**: `Animate/characters/<slug>/models/`

## Key Data Locations

- Project: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/`
- Animate data: `.../Animate/` (scenes.json, places.json, characters/, backgrounds/, objects/)
- Scene with demo data: `1.05.0 - Silver` (2112 frames, Mark Price + Johnny Ward)

## Libretto Extraction Results

- **41 unique locations** identified (needs ~55 background plates with lighting variants)
- **91 props** catalogued across 8 categories
- Firebase Comms Room is most reused location (8 scenes)
- The father's journal is the central prop (15 scenes)

## Next Steps (Priority Order)

1. **Wire the new engine into the 3D view** — Replace/supplement the existing harness with ScenePreviewRenderer
2. **Import Meshy.ai character models** — Gary is generating these now
3. **Import background plates** — Gary is generating these now
4. **Apply cel shading** — Call CelShadingTechnique.apply() on the SCNView
5. **Build depth estimation** — Download Depth Anything V2 CoreML, run on backgrounds
6. **Build the LayoutGPT-style placement** — Local LLM with structured prompts for text→coordinates
7. **Pre-fill Places grid** with the 41 extracted locations
8. **Pre-fill Props list** with the 91 extracted props

## Build/Deploy

```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer"
swift build -c release
cp .build/release/Opera "/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera"
codesign --sign - --force --deep "/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
```

## AI Research Findings (For Reference)

- **Depth Anything V2**: CoreML model at `apple/coreml-depth-anything-v2-small`, 49.8MB, 25ms on M3, Apache 2.0
- **LayoutGPT**: Text→coordinates via LLM prompt patterns, MIT license
- **Spider-Verse technique**: Per-character keyframe density at constant 24fps — ones/twos/threes
- **Cel shading**: SCNShadable fragment modifier for banded lighting + SCNTechnique for edge outlines
