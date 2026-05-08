# Phase 2 Handoff: 3D Pre-Vis Core

**Status:** Ready for implementation  
**Phase 1 prerequisite:** Meshy API pipeline built, compiles, `CharactersPageView` has collapsible 3D generation pane  
**Architecture decision:** WKWebView + vendored three.js (same proven stack as PlacesMap3DView, since SceneKit was explicitly abandoned in this codebase)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Step 1: Create three.js Pre-Vis Viewer](#2-step-1-create-threejs-pre-vis-viewer)
3. [Step 2: Data Model Extensions](#3-step-2-data-model-extensions)
4. [Step 3: Previs3DView (Swift Wrapper)](#4-step-3-previs3dview-swift-wrapper)
5. [Step 4: ScenesWorkspace Tab Switcher](#5-step-4-scenesworkspace-tab-switcher)
6. [Step 5: Integrate Previs Pane into AnimatePageView](#6-step-5-integrate-previs-pane-into-animatepageview)
7. [Step 6: Build & Bundle Integration](#7-step-6-build--bundle-integration)
8. [Test Criteria](#8-test-criteria)
9. [Checkpoints (Build Each Step)](#9-checkpoints-build-each-step)

---

## 1. Architecture Overview

```
ScenesWorkspace (SwiftUI)
├── sidebar: SidebarView (existing)
├── center: "Imagine" | "Previs 3D" segmented control (NEW)
│   ImagineScenesPageView (existing) ── stays unchanged
│   Previs3DContainerView (NEW) ── contains toolbar + Previs3DView
│       ├── Previs3DToolbar (NEW) ── mode buttons, keyframe pills, capture button
│       └── Previs3DView (NEW) ── WKWebView loading three.js viewer
│
├── inspector: InspectorView (existing)

Previs3DView ── WKWebView loading file:// <project>/previs-web/index.html
    └── three.js scene (JS)
        ├── GLTFLoader → loads rigged GLBs from Characters/
        ├── TransformControls → click-drag pose/translate/rotate
        ├── OrbitControls → camera navigation
        ├── SkeletonHelper + custom bone handles → pose bones
        ├── Ground plane + grid → environment
        ├── Camera keyframe system → shot beginning/middle/end
        └── Export → renderer.domElement.toDataURL('image/jpeg', 0.85) at 1280×720
```

**Data flow:**
```
Swift (AnimateStore)          JS Bridge            three.js
─────────────────────→     ────────────→     ─────────────
ShotPrevis3DState JSON    │  postMessage    │  parse scene
                           │                 │  load GLBs
                           │  ←────────────  │  scene snapshot
                           │  camera/pose    │  updates
User taps "Capture"       │                 │
←──────── JPEG dataURL    │  ←────────────  │  toDataURL()
→ save to disk            │                 │
```

---

## 2. Step 1: Create three.js Pre-Vis Viewer

### File: `Packages/Animate/Sources/AnimateUI/Resources/previs-web/index.html`

Purpose: HTML shell loaded into WKWebView. Same structure as `PlacesMap3DView` viewer.

Key constraint from PlacesMap3DView documentation (read the source for exact patterns):
- Load three.js from `file://` vendor directory (do NOT use import maps — they fail silently)
- `loadFileURL(_:, allowingReadAccessTo:)` must point at the parent so sibling files resolve
- `crossOrigin = ''` on any texture/image load
- `preserveDrawingBuffer: true` for capture (ONLY during capture)

Copy the `PlacesMap3DView` `index.html` loading pattern exactly, but change the JS entry file from `main.js` to `previs-core.js`.

### Files: `Packages/Animate/Sources/AnimateUI/Resources/previs-web/*.js`

**File: `previs-core.js`**

Purpose: Scene initialiser, loads GLB characters, manages camera, handles the JS bridge.

Copy the init pattern from:
- `Scripts/3d-map-pipeline/viewer/main.js` (scene/renderer/camera/controls init)

Replace terrain/buildings/roads with:
- Ground plane (PlaneGeometry + ShadowMaterial)
- Grid helper (1m squares, dark grey on lighter grey)
- Sky gradient (simple CSS-linear-gradient equivalent color)

**File: `previs-character.js`**

Purpose: Character loading, skeleton extraction, bone handle rendering.

Requirements per conversation with Gary:
- GLB loaded via GLTFLoader
- Extract skeleton from `SkinnedMesh`
- Render bone handles as **wireframe spheres + cylinders** at joint positions
- Color coding: head=cyan, spine=red, arms=blue, legs=green
- Bone names mapped from Mixamo/standard skeleton to display labels
- Simple poses supported: head turn, arm raise, spine bend

**File: `previs-controls.js`**

Purpose: Interaction controls.

Requirements:
- `OrbitControls` (already vendored) for camera rotation/zoom/pan
- `TransformControls` for selected character/object translate/rotate/scale
- Click on body = select whole character
- Click on colored joint sphere = select bone for rotation
- Keyboard shortcuts: T (translate), R (rotate), E (scale) — same as Blender/Unity
- Shift+click to multi-select (nice-to-have, not critical)

**File: `previs-camera.js`**

Purpose: Camera keyframes per shot moment.

Requirements:
- Save camera position + lookAt + FOV for Beginning/Middle/End keyframes
- Shot-type presets: `wide` (fov 60, distance far), `medium` (fov 45), `close` (fov 35), `extreme_close` (fov 25), etc.
- Smooth interpolate for scrub preview (linear interpolation is fine)

**File: `previs-export.js`**

Purpose: JPEG export at 1280×720.

Requirements:
- Set `preserveDrawingBuffer: true` before render
- Render at 16:9 aspect ratio
- `renderer.domElement.toDataURL('image/jpeg', 0.85)` → returns base64 string
- Send back to Swift via bridge
- Turn off `preserveDrawingBuffer` after capture
- Support three frames: Beginning / Middle / End

**File: `previs-environment.js`**

Purpose: Environment rendering.

Requirements:
- Ground plane: grid + shadow-receiving plane
- Simple backdrop: colored plane behind the scene, or hemisphere with a gradient
- Lighting preset system based on `timeOfDay` JSON field:
  - golden-hour: warm directional, long shadows, warm fill
  - noon: bright white directional, minimal fill
  - night-interior: blue ambient, point/spot lights
  - overcast: soft diffused, no hard shadows

**File: `previs-touch.js`**

Purpose: Touch and Apple Pencil input (for iPad PWA integration).

For now, stub this file with basic touch events mapped to orbit/pan controls. Complete iPad integration comes in Phase 4.

**File: `previs-web/style.css`**

Purpose: HUD overlay styling.

Requirements:
- Mode buttons floating top-left (Select, Translate, Rotate, Scale, Pose)
- Keyframe pills floating bottom-center (Beginning, Middle, End, Capture)
- Status text floating top-right (loading / error)
- Invisible by default, fade in on scene ready

### Vendored Dependencies

Reuse the existing vendored three.js from `Scripts/3d-map-pipeline/viewer/vendor/three/`. You can either:
- **Option A:** Copy into `previs-web/vendor/three/` (duplicates ~1MB)
- **Option B:** Symlink from `Scripts/3d-map-pipeline/viewer/vendor/three/` (preferred)

Additional three.js addons to add (if not already present):
- `GLTFLoader.js`
- `TransformControls.js`
- `SkeletonHelper.js`
- `OrbitControls.js` (already present from map viewer)

### Exact three.js loading pattern (copy from PlacesMap3DView viewer):

```js
// Use explicit relative paths — DO NOT use import map
import * as THREE from './vendor/three/three.module.js?v=1';
import { OrbitControls } from './vendor/three/addons/controls/OrbitControls.js?v=1';
import { GLTFLoader } from './vendor/three/addons/loaders/GLTFLoader.js?v=1';
import { TransformControls } from './vendor/three/addons/controls/TransformControls.js?v=1';
```

(The `?v=1` cache-bust is critical — read `PlacesMap3DView.swift` line 6-9 for why.)

---

## 3. Step 2: Data Model Extensions

### Existing model (do NOT modify `CodingKeys` unless backwards compatible):
`Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`

Search for `struct AnimationSceneShot` (around line 190). Add a field (with a new CodingKey **appended** to the enum, not inserted:

```swift
struct AnimationSceneShot: Identifiable, Codable, Sendable {
    // ... existing fields remain unchanged ...

    /// NEW: 3D previsualization state for this shot.
    /// Added Phase 2, 2026-05-07. Default nil for backward compatibility.
    var previs3DState: ShotPrevis3DState? = nil

    // In the CodingKeys enum, ADD only the new key at the END:
    enum CodingKeys: String, CodingKey {
        // ... keep all existing keys in SAME ORDER ...
        case previs3DState  // <-- ADD THIS LAST
    }
}
```

### New file: `Packages/Animate/Sources/AnimateUI/Models/ShotPrevis3DState.swift`

```swift
import Foundation
import simd

@available(macOS 26.0, *)
struct ShotPrevis3DState: Codable, Sendable, Equatable {
    /// Camera states for each keyframe moment
    var keyframes: [PrevisKeyframe] = [
        PrevisKeyframe(label: "beginning", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50),
        PrevisKeyframe(label: "middle", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50),
        PrevisKeyframe(label: "end", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50)
    ]

    /// Character poses in this shot
    var characterPoses: [String: CharacterPose3D] = [:]

    /// Object transforms in this shot
    var objectTransforms: [UUID: ObjectTransform3D] = [:]

    /// Environment configuration
    var environmentConfig: PrevisEnvironmentConfig = PrevisEnvironmentConfig()

    /// Time of day / lighting preset name
    var lightingPreset: String = "golden-hour"
}

@available(macOS 26.0, *)
struct PrevisKeyframe: Codable, Sendable, Equatable {
    var label: String  // "beginning", "middle", "end"
    var position: [Double]
    var lookAt: [Double]
    var fov: Double
}

@available(macOS 26.0, *)
struct CharacterPose3D: Codable, Sendable, Equatable {
    var characterSlug: String
    var costumeName: String

    // Root transform
    var position: SIMD3<Double>
    var rotation: SIMD3<Double>  // euler angles in degrees
    var scale: Double

    // Optional bone rotations (head, spine, armL_upper, armR_upper, etc.)
    var boneRotations: [String: [Double]]?
}

@available(macOS 26.0, *)
struct ObjectTransform3D: Codable, Sendable, Equatable {
    var objectID: UUID
    var position: SIMD3<Double>
    var rotation: SIMD3<Double>
    var scale: Double
}

@available(macOS 26.0, *)
struct PrevisEnvironmentConfig: Codable, Sendable, Equatable {
    var placeID: String? = nil
    var groundType: String = "grid"
    var backdropColor: String = "#1a1f27"
}
```

**IMPORTANT:** `simd` vectors (`SIMD3<Double>`) are already `Codable` and `Sendable` in Swift 6.2, so this just works. The JSON will serialize as arrays `[x, y, z]`.

**IMPORTANT backward compatibility:** Do NOT renumber or reorder existing `CodingKeys`. For `AnimationSceneShot`, if the `previs3DState` key is ADDED at the end, existing JSON will decode with `previs3DState: nil` (which is the default, so that's fine). But you also need to handle the case where existing JSON was written before this field existed — `decodeIfPresent` is the safe pattern:

```swift
previs3DState = try container.decodeIfPresent(ShotPrevis3DState.self, forKey: .previs3DState)
```

---

## 4. Step 3: Previs3DView (Swift Wrapper)

### New file: `Packages/Animate/Sources/AnimateUI/Views/Previs3DView.swift`

**Pattern to copy EXACTLY:** `PlacesMap3DView.swift` (740 lines).

Key differences from PlacesMap3DView:
1. Load `previs-web/index.html` instead of `map3d-viewer/index.html`
2. Pass scene JSON via `evaluateJavaScript` after load
3. Receive JPEG capture results via JS bridge (`window.webkit.messageHandlers.previsCapture`)
4. No regenerate pipeline, no diagnostics panel needed (for now)
5. Reload mechanism: `.id(sceneDataHash)` instead of `reloadToken`

The view takes two inputs:
```swift
struct Previs3DView: View {
    var sceneJSON: String     // JSON representation of ShotPrevis3DState
    var characterGLBPaths: [(slug: String, costume: String, path: String)]
    var onCaptureResult: ((String, Data) -> Void)?  // (label, jpegData)
    var onCaptureError: ((String) -> Void)?
}
```

**JS Bridge naming:**
- Register `WKUserContentController` with name `"previsCapture"` (for image data)
- Register `"previsSceneUpdate"` (for bidirectional updates)
- Or keep it simple and just use `evaluateJavaScript` to push JSON every time state changes (simpler, less code)

**Critical rule from PlacesMap3DView (line 34-38):**
- `updateNSView` MUST stay empty
- Reloads happen via `.id(hash)` on the parent view, which tears down and rebuilds the NSView
- Do NOT compare `web.url != url` in `updateNSView` — causes infinite reload loop

### New file: `Packages/Animate/Sources/AnimateUI/Views/Previs3DToolbar.swift`

This is a SwiftUI toolbar that floats above the Previs3DView (via ZStack overlay).

```swift
struct Previs3DToolbar: View {
    @Binding var activeMode: PrevisMode
    @Binding var activeKeyframe: PrevisKeyframeLabel
    var onCapture: () -> Void
}

enum PrevisMode: String, CaseIterable {
    case select, translate, rotate, scale, poseBone
}

enum PrevisKeyframeLabel: String, CaseIterable {
    case beginning, middle, end
}
```

UI layout:
- Top row (HStack): mode segmented picker (Select / Translate / Rotate / Scale / Pose)
- Bottom row (HStack): keyframe pills (Beginning / Middle / End) + Capture button

Styling: Use `OperaChromeTheme` if available, otherwise standard SwiftUI with `.controlSize(.small)`.

### New file: `Packages/Animate/Sources/AnimateUI/Views/Previs3DContainerView.swift`

This wraps the WKWebView + toolbar together:

```swift
struct Previs3DContainerView: View {
    @Bindable var store: AnimateStore
    let scene: AnimationScene
    let shot: AnimationSceneShot

    @State private var activeMode: PrevisMode = .select
    @State private var activeKeyframe: PrevisKeyframeLabel = .beginning

    var body: some View {
        ZStack {
            Previs3DView(
                sceneJSON: buildSceneJSON(),
                characterGLBPaths: resolveCharacterGLBs(),
                onCaptureResult: handleCapture
            )

            VStack {
                Previs3DToolbar(
                    activeMode: $activeMode,
                    activeKeyframe: $activeKeyframe,
                    onCapture: { captureActiveKeyframe() }
                )
                .padding()
                Spacer()
            }
        }
    }
}
```

---

## 5. Step 4: ScenesWorkspace Tab Switcher

### File: `Packages/Animate/Sources/AnimateUI/ScenesWorkspace.swift`

Current behavior (read lines 51-125): The center pane shows `ImagineScenesPageView` unconditionally.

Add a `@State` variable and a segmented control to switch between Imagine and Previs 3D:

```swift
@State private var activeTab: ScenesWorkspaceTab = .imagine

enum ScenesWorkspaceTab: String, CaseIterable {
    case imagine = "Imagine"
    case previs3D = "Previs 3D"
}
```

In the `workspaceBody` (around line 121), wrap the center content:

```swift
// Inside the center pane (after the header row, before ImagineScenesPageView)
VStack(spacing: 0) {
    // Segmented tab switcher
    Picker("", selection: $activeTab) {
        ForEach(ScenesWorkspaceTab.allCases, id: \.self) { tab in
            Text(tab.rawValue).tag(tab)
        }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)

    switch activeTab {
    case .imagine:
        ImagineScenesPageView(store: store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .previs3D:
        if let scene = store.selectedScene, let shot = store.selectedShot {
            Previs3DContainerView(store: store, scene: scene, shot: shot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OperaChromeEmptyState(
                systemImage: "cube",
                title: "Select a Shot",
                message: "Choose a shot from the sidebar to start pre-visualizing in 3D."
            )
        }
    }
}
```

**IMPORTANT:** The `ScenesWorkspace` currently hosts `ImagineScenesPageView`. The tab switcher should be a thin bar above it, not replacing the whole layout. Look at how `AnimatePageView` handles its own internal tab switching — it uses a similar pattern.

---

## 6. Step 5: Integrate Previs Pane into AnimatePageView

Wait — I need to clarify where exactly the Previs tab lives. Gary said "a new tab in the scenes workspace". The `ScenesWorkspace` is the top-level workspace for Scene work. The `AnimatePageView` is the per-scene detail view that shows shot tabs, timeline, etc.

Looking at the nav structure from `ContentView.swift`:
- `.scenes` → `AnimatePageView` (line 287)
- `.animate` → also `AnimatePageView` (line 289)

The `ScenesWorkspace` (used by both `.scenes` and `.animate` nav pages) contains `ImagineScenesPageView`. That's the correct place to add the Previs 3D tab.

So Step 4 (ScenesWorkspace) is correct. No changes needed in `AnimatePageView` for initial integration.

However, you MAY want to add a "Previs" quick-link button inside `AnimatePageView` or `ImagineScenesPageView` that switches to the Previs tab. Not required for Phase 2.

---

## 7. Step 6: Build & Bundle Integration

### File: `Scripts/build-app.sh`

Find the existing map viewer embed logic (around line 170-177):

```bash
if [[ -d "$PROJECT_DIR/Scripts/3d-map-pipeline/viewer" ]]; then
    rm -rf "$RESOURCES_DIR/map3d-viewer"
    cp -R "$PROJECT_DIR/Scripts/3d-map-pipeline/viewer" "$RESOURCES_DIR/map3d-viewer"
    echo "Embedded 3D map viewer: $RESOURCES_DIR/map3d-viewer"
fi
```

ADD after it:

```bash
# Embed the 3D previs viewer
if [[ -d "$PROJECT_DIR/Packages/Animate/Sources/AnimateUI/Resources/previs-web" ]]; then
    rm -rf "$RESOURCES_DIR/previs-web"
    cp -R "$PROJECT_DIR/Packages/Animate/Sources/AnimateUI/Resources/previs-web" "$RESOURCES_DIR/previs-web"
    echo "Embedded 3D previs viewer: $RESOURCES_DIR/previs-web"
fi
```

### File: `Packages/Animate/Package.swift`

Add the previs-web resources to the `AnimateUI` target:

```swift
resources: [
    .copy("Resources/Models3D"),
    .copy("Resources/gemini_inspiration_batch.py"),
    .copy("Resources/storyboard-web"),
    .copy("Resources/previs-web")  // <-- ADD THIS
]
```

---

## 8. Test Criteria

### Build Test
```bash
cd /Volumes/Storage\ VIII/Programming/Amira\ Writer
swift build -c release --product Opera
```
Must compile with zero errors.

### Functional Test Checklist

| # | Test | Expected |
|---|------|----------|
| 1 | Open project → go to Scenes workspace | "Imagine \| Previs 3D" tab switcher appears at top of center pane |
| 2 | Select a shot from sidebar | Previs 3D tab becomes active-able (or shows the empty state if no models) |
| 3 | Switch to "Previs 3D" tab | WKWebView loads, black canvas briefly, then three.js scene renders |
| 4 | Drag mouse on canvas | Camera orbits (OrbitControls) |
| 5 | Scroll wheel | Camera zooms |
| 6 | Select a character mode, click on canvas | Character GLB loads from disk (if exists), shows on ground plane |
| 7 | Click "Capture" button on Beginning keyframe | JPEG saved to disk at 1280×720 |
| 8 | Switch to Middle keyframe, move camera, capture | Different camera angle captured |
| 9 | Switch back to "Imagine" tab | `ImagineScenesPageView` reappears unchanged |

### Data Persistence Test
| # | Test | Expected |
|---|------|----------|
| 10 | Pose a character in Previs, switch to Imagine, switch back | Character position retained (state persisted in `AnimationSceneShot.previs3DState`) |

---

## 9. Checkpoints (Build Each Step)

**Checkpoint 1:** After Step 2 (data models). Build with:
```bash
swift build -c release --product Opera
```
Verify `ShotPrevis3DState.swift` has no errors. Verify `AnimateModels.swift` still decodes/encodes correctly by running existing tests (if available).

**Checkpoint 2:** After Step 3 (Previs3DView wrapper). Build. The viewer code can just load `index.html` and show a "loading" spinner.

**Checkpoint 3:** After Step 4 (ScenesWorkspace tab). Build. Switch between Imagine/Previs tabs. Previs tab can show placeholder colored cubes for now.

**Checkpoint 4:** After Step 1 (JS viewer). Build. Load the app, switch to Previs tab, verify a ground plane + grid renders. You can test by manually creating a simple `test-scene.json` and loading it.

**Checkpoint 5:** After all steps integrated. Build. End-to-end test: select shot → load Previs → move camera → capture → verify JPEG on disk.

---

## File Inventory (Complete List)

### New Swift Files
| File | Lines Est. |
|---|---|
| `Models/ShotPrevis3DState.swift` | ~120 |
| `Views/Previs3DView.swift` | ~300 (copy PlacesMap3DView pattern) |
| `Views/Previs3DToolbar.swift` | ~120 |
| `Views/Previs3DContainerView.swift` | ~80 |

### New JS/CSS/HTML Files
| File | Lines Est. |
|---|---|
| `Resources/previs-web/index.html` | ~60 (copy from map viewer) |
| `Resources/previs-web/previs-core.js` | ~400 |
| `Resources/previs-web/previs-character.js` | ~350 |
| `Resources/previs-web/previs-controls.js` | ~300 |
| `Resources/previs-web/previs-camera.js` | ~200 |
| `Resources/previs-web/previs-export.js` | ~100 |
| `Resources/previs-web/previs-environment.js` | ~150 |
| `Resources/previs-web/previs-touch.js` | ~60 (stub) |
| `Resources/previs-web/style.css` | ~200 |

### Modified Swift Files
| File | Change |
|---|---|
| `Models/AnimateModels.swift` | Add `previs3DState` field + CodingKey |
| `Views/ScenesWorkspace.swift` | Add tab switcher (Imagine \| Previs 3D) |
| `Models/AnimatePage.swift` | No change needed for Phase 2 |

### Modified Build Files
| File | Change |
|---|---|
| `Scripts/build-app.sh` | Embed previs-web into bundle Resources |
| `Packages/Animate/Package.swift` | Add `.copy("Resources/previs-web")` |

---

## Known Gotchas (Critical)

1. **Import maps fail silently in WKWebView under `file://`** — use explicit relative paths like `./vendor/three/three.module.js` (read `PlacesMap3DView.swift` lines 1-23)
2. **`updateNSView` must stay empty** — comparing URLs causes infinite reload loop (read `PlacesMap3DView.swift` lines 35-39)
3. **`preserveDrawingBuffer`** must be `true` only during capture — set it dynamically before render, then set back to `false`
4. **Do NOT re-order existing CodingKeys** — only APPEND new keys at the end
5. **SceneKit is abandoned** — do NOT touch `SCNView`. WKWebView + three.js is the canonical stack
6. **three.js vendor** — share the directory from `Scripts/3d-map-pipeline/viewer/vendor/three/` to avoid bloat. Symlink preferred.
7. **Swift 6.2 strict concurrency** — `MeshyService` had to be `@MainActor`. The JS bridge callbacks will need similar attention.

---

## Context Appendix

### How `PlacesMap3DView` Works (copy this pattern)

- 740-line file in `Packages/Animate/Sources/AnimateUI/Views/PlacesMap3DView.swift`
- `NSViewRepresentable` wrapping `WKWebView`
- Loads `file://` HTML from app Resources
- JS bridge `map3dLog` forwards console errors to Swift diagnostics
- Screenshot capture via `evaluateJavaScript` calling `renderer.domElement.toDataURL()`
- Reload via `.id(reloadToken)` (forced recreation of NSView)

### How `StoryboardAPIServer` Works (for Phase 4 context)

- File: `Packages/Animate/Sources/AnimateUI/Services/StoryboardServer/StoryboardRouter.swift`
- Port 19850, serves `Resources/storyboard-web/` to iPad
- Assets served via `StoryboardAssets.swift` whitelist
- Same pattern can serve `previs-web/` to iPad in Phase 4

### Meshy API Pipeline (Phase 1, completed)

- Models stored at `Animate/Characters/{slug}/3d-models/{taskID}/model.glb`
- `Character3DModel` data model already supports GLB paths
- `resolvedCharacterAssetURL(for:)` already resolves relative project paths

### End of Handoff Document
