# Characters Queue Fix, Places Draw Things, Animation Pipeline, 3D Viewer

**Date:** 2026-04-04  
**Status:** Draft  
**Scope:** 4 feature areas across Characters page, Places page, and Animate page

---

## 1. Characters Page — Queue Separation & UX Cleanup

### 1.1 Problem

`store.batchQueue: [BatchQueueItem]` is a single shared queue holding `GeminiGenerationDraft` items. Character reference sheets, inspiration images, and 3D pipeline concept art all go into the same queue. The Meshy3DGenerationPane has its own local `@State batchQueue` that doesn't persist across pane collapses. The Inspector's "Submit All" processes everything through Gemini indiscriminately. Adding a costume reference and clicking generate can trigger both Gemini and Meshy generation.

### 1.2 Solution — Split Into Typed Queues

Replace `store.batchQueue: [BatchQueueItem]` with two separate typed queues on `AnimateStore`:

```swift
// Gemini image generation (references, inspiration, concept art)
var geminiQueue: [GeminiBatchQueueItem] = []

// Meshy 3D model generation from reference images  
var meshyQueue: [MeshyBatchQueueItem] = []
```

**`GeminiBatchQueueItem`** — same fields as current `BatchQueueItem` (characterID, characterName, characterSlug, draftTitle, draft, outputRootRelativePath, dateQueued, groupingKey).

**`MeshyBatchQueueItem`** — new struct:
```swift
struct MeshyBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var characterID: UUID
    var characterName: String
    var costumeName: String
    var images: [PoseImage]          // reference images to send to Meshy
    var config: MeshyGenerationConfig // polycount, topology, texture, formats
    var dateQueued: Date = Date()
}
```

Move Meshy3DGenerationPane's local `@State batchQueue` into `store.meshyQueue` so it persists globally.

### 1.3 Queue Controls UI

Pinned bar at the top of the Characters middle pane, above all collapsible sections:

```
┌─────────────────────────────────────────────────────┐
│  GENERATION QUEUES                                   │
│  ┌─────────────────────┐ ┌─────────────────────────┐│
│  │ ✦ Gemini  3 items   │ │ ◆ Meshy 3D  1 item     ││
│  │ [Submit] [Clear]    │ │ [Submit] [Clear]        ││
│  │ Est: $0.45 / ~2min  │ │ Est: 300 credits        ││
│  └─────────────────────┘ └─────────────────────────┘│
└─────────────────────────────────────────────────────┘
```

- Each queue shows item count, estimated cost, independent Submit/Clear
- Clicking item count expands inline list with per-item remove buttons
- Progress indicators appear in-place during processing
- Both queues collapsed to a single-line summary when empty

### 1.4 Routing Changes

- `CharacterReferenceWorkflowSheet` "Add to Batch" → `store.addToGeminiQueue()`
- `Meshy3DGenerationPane` "Generate All Costumes" → `store.addToMeshyQueue()`
- `InspectorView` batch tab removed when on Characters page (redundant)
- `Animate3DProductionPreviewView` pipeline items → `store.addToGeminiQueue()` with `outputRootRelativePath`

### 1.5 Files to Modify

- `AnimateStore.swift` — replace `batchQueue` with `geminiQueue` + `meshyQueue`, add typed methods
- `CharactersPageView.swift` — add pinned queue controls bar at top of `characterDetail`
- `CharacterReferenceWorkflowSheet.swift` — route to `addToGeminiQueue()`
- `Meshy3DGenerationPane.swift` — remove local `@State batchQueue`, use `store.meshyQueue`
- `InspectorView.swift` — remove batch tab when `currentPage == .characters`, update `submitBatchQueue` to use `geminiQueue`

---

## 2. Places Page — Draw Things Integration

### 2.1 Current State

`DrawThingsPlaceGenerationService` exists with full HTTP client (`/sdapi/v1/txt2img`). `DrawThingsPlaceConfig` model exists. Zero UI integration.

### 2.2 New Collapsible Pane: "Local Generation (Draw Things)"

Added to the Places detail view after existing sections.

#### 2.2.1 Layout

```
┌─────────────────────────────────────────────────────────┐
│  ▾ LOCAL GENERATION (DRAW THINGS)          [● Connected]│
│                                                         │
│  Prompt:                                                │
│  ┌─────────────────────────────────────────────────┐    │
│  │ [auto-generated or user-edited]                 │    │
│  └─────────────────────────────────────────────────┘    │
│  [✦ Auto-Generate Prompt]  (MiniMax M2.7)               │
│                                                         │
│  Negative Prompt:                                       │
│  ┌─────────────────────────────────────────────────┐    │
│  │ [default negative, editable]                    │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  Resolution: [preset ▾] W: [____] H: [____]            │
│  Presets: 1536x864 / 1920x1080 / 1024x576 / Custom     │
│                                                         │
│  Steps: [28 ▸]   CFG: [7.5 ▸]   Seed: [-1    ]       │
│                                                         │
│  ── img2img ──────────────────────────────────────      │
│  Source: [None ▾]  Denoising: [0.75 ▸]                 │
│  (dropdown: approved image, variants, angle images)     │
│                                                         │
│  [Generate]  [Generate 4x]  [Generate All Angles]       │
│                                                         │
│  Results (staging):                                      │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐                          │
│  │    │ │    │ │    │ │    │  right-click:             │
│  └────┘ └────┘ └────┘ └────┘  → Add to Variants       │
│                                  → Set as Approved      │
│                                  → Delete               │
└─────────────────────────────────────────────────────────┘
```

#### 2.2.2 Prompt Generation

Uses MiniMax M2.7 API (text completion) to generate Stable Diffusion prompts from place metadata.

New `MiniMaxPromptService`:
- API key stored in AnimateStore settings (new `miniMaxAPIKey` field)
- Endpoint: MiniMax chat completion API
- Input: place name, category (Interior/Exterior), notes, scene usage context
- Output: SD-optimized prompt string
- Rate limit: 10 calls/min, circuit breaker after 5 consecutive failures

#### 2.2.3 Generation Modes

- **Generate** — single txt2img (or img2img if source selected)
- **Generate 4x** — 4 images with incrementing seeds
- **Generate All Angles** — one image per required camera angle from `store.requiredCameraShots(for: placeID)`, prompt modified per angle

#### 2.2.4 Results Staging

Generated images go to `<animateURL>/Animate/backgrounds/<place-slug>/staging/`. Right-click context menu:
- "Add to Place Variants" → copies to place's `imagePaths`
- "Set as Approved Image" → sets `approvedImagePath`
- "Use as Angle Image" → prompts for camera shot / angle / time-of-day tags
- "Delete" → removes from staging

#### 2.2.5 Connection Status

On pane expand, ping Draw Things at configured host:port. Show green dot "Connected" or red dot "Not Running — start Draw Things and enable API server".

#### 2.2.6 Resolution Settings

User-configurable width and height fields with preset dropdown:
- 1536 x 864 (16:9, high quality)
- 1920 x 1080 (16:9, full HD)
- 1024 x 576 (16:9, fast draft)
- Custom (free-form width/height entry)

Defaults stored in `DrawThingsPlaceConfig` (already exists).

#### 2.2.7 Files to Create/Modify

- **New:** `MiniMaxPromptService.swift` — MiniMax M2.7 API client for prompt generation
- **New:** `DrawThingsGenerationPane.swift` — the collapsible pane UI
- **Modify:** `PlacesPageView.swift` — add the new pane to detail view
- **Modify:** `AnimateStore.swift` — add `miniMaxAPIKey`, Draw Things connection status
- **Modify:** `DrawThingsPlaceGenerationService.swift` — add img2img support, seed control
- **Modify:** `DrawThingsPlaceConfig` in `PlacesIndexModels.swift` — add resolution presets

---

## 3. Animation Engine Pipeline — Shot Production System + Vidu Q3

### 3.1 Overview

A new shot-by-shot production pipeline in the Animate page middle pane. For every scene: auto-pull background plates. For every shot: generate shot-specific backgrounds, pull character/costume references, generate first and last frames, define motion direction, send to Vidu Q3 for video generation.

### 3.2 New Data Models

#### 3.2.1 ShotBackgroundPlate

```swift
struct ShotBackgroundPlate: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sourceBackgroundID: UUID       // parent BackgroundPlate
    var cameraShot: CameraShot?
    var prompt: String = ""            // auto-built from scene context
    var generatedImagePath: String?
    var approvedImagePath: String?
    var variants: [String] = []        // multiple generations to pick from
}
```

#### 3.2.2 ShotFrameGeneration

```swift
struct ShotFrameGeneration: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    
    // First frame
    var firstFramePrompt: String = ""
    var firstFrameImagePath: String?
    var firstFrameVariants: [String] = []
    var firstFrameApproved: Bool = false
    
    // Last frame
    var lastFramePrompt: String = ""
    var lastFrameImagePath: String?
    var lastFrameVariants: [String] = []
    var lastFrameApproved: Bool = false
    
    // Direction between frames
    var motionDirection: String = ""
    var animationStyleNotes: String = ""
    
    // Timing
    var durationSeconds: Double = 4.0  // max 16s for Vidu Q3
    var aspectRatio: String = "16:9"
    
    // Vidu result
    var viduTaskID: String?
    var viduStatus: ViduTaskStatus = .idle
    var viduOutputPath: String?
}

enum ViduTaskStatus: String, Codable, Sendable {
    case idle
    case queued
    case generating
    case succeeded
    case failed
}
```

#### 3.2.3 AnimationStylePreset

```swift
struct AnimationStylePreset: Codable, Sendable {
    var name: String = "Slightly Anime"
    var frameRateStyle: String = "variable"   // "variable" / "constant"
    var holdFrames: Bool = true               // anime movement holds
    var impactFrames: Bool = true             // snap to key poses
    var motionBlurStyle: String = "speed lines" // "speed lines" / "smear" / "none"
    var aestheticNotes: String = ""           // free-form style direction
}
```

Scene-level field: `AnimationScene.animationStylePreset: AnimationStylePreset?`

### 3.3 Background Plate Pipeline

**Scene-level:** Each scene's `backgroundID` links to a `BackgroundPlate` with an approved image. This already works.

**Shot-level (new):** For each `AnimationSceneShot`, a `ShotBackgroundPlate` is generated:
1. MiniMax M2.7 writes a prompt from: scene direction tags + parent place description + shot camera angle + time of day
2. Draw Things generates the plate locally (txt2img from prompt, or img2img from scene-level approved plate)
3. Multiple variants generated; user approves one
4. Fallback: Gemini generation if Draw Things unavailable

Storage: `<animateURL>/Animate/shots/<scene-slug>/shot-<index>/backgrounds/`

### 3.4 First Frame / Last Frame Generation

For each shot:
1. **Auto-pull shot background plate** — the approved `ShotBackgroundPlate`
2. **Auto-pull character references** — from `shot.focusCharacterID` + `scene.characterIDs`, resolve to approved costume reference images for the appropriate wardrobe
3. **Build frame prompts** — MiniMax M2.7 composites a prompt describing:
   - The background (from shot plate)
   - Character positions, expressions, poses (from scene direction tags)
   - Camera framing (from shot.cameraShot)
   - Animation style preset (injected for consistency)
   - Frame 1: initial state. Frame N: final state after motion.
4. **Generate images** — via Draw Things (preferred) or Gemini
5. **User reviews and approves** — picks best variant for first frame and last frame

Storage: `<animateURL>/Animate/shots/<scene-slug>/shot-<index>/frames/`

### 3.5 Shot Production Strip UI

Located in the Animate page middle pane. Layout order top to bottom:
1. 3D Preview (existing)
2. Shot Filmstrip (horizontal scroll, new)
3. Shot Production Strip for selected shot (new)

#### 3.5.1 Shot Filmstrip

Horizontal scrollable strip showing all shots in the selected scene:

```
┌─────┐ ┌─────┐ ┌══════┐ ┌─────┐ ┌─────┐
│ S1  │ │ S2  │ ║ S3 ◉ ║ │ S4  │ │ S5  │
│wide │ │med  │ ║close ║ │med  │ │wide │
│ ✓✓  │ │ ✓·  │ ║ ··   ║ │ ··  │ │ ··  │
└─────┘ └─────┘ └══════┘ └─────┘ └─────┘
```

Each chip shows: shot index, camera type, frame approval status (✓✓ = both approved, ✓· = one approved, ·· = neither). Selected shot highlighted. Click to select.

#### 3.5.2 Shot Production Strip

Collapsible detail strip for the actively selected shot. Contains:

- **Scene/background info row:** Scene name, BG plate thumbnail + approval status, camera shot type
- **Shot background plate:** Thumbnail, [Regenerate] button, prompt editor
- **Characters row:** Auto-pulled character references with costume name and approval checkmark
- **First Frame / Last Frame cards:** Side by side, each with:
  - Image preview (or empty placeholder)
  - Editable prompt field
  - [Generate] button (immediate, via Draw Things)
  - [☐ Queue] checkbox (for Vidu batch)
  - Variant count and picker
- **Motion Direction:** Editable text field describing what happens between first and last frame
- **[✦ Auto-Generate Direction]** button — MiniMax M2.7 generates from scene directions
- **Animation Style:** Dropdown preset selector + editable notes
- **Duration:** Slider 0.5s to 16s (Vidu Q3 max)
- **Aspect Ratio:** Dropdown (16:9 default, with note about 21:9 crop)
- **Vidu Q3 section:** [Send to Vidu] [Queue for Batch] buttons, status indicator, result video player
- **Navigation:** ◂ Prev Shot / Next Shot ▸ buttons

### 3.6 Vidu Q3 API Integration

New `ViduAPIService`:

```swift
class ViduAPIService {
    // Auth
    var apiKey: String
    
    // Create generation task
    func createTask(
        firstFrameImage: Data,
        lastFrameImage: Data,
        motionPrompt: String,
        durationSeconds: Double,
        aspectRatio: String
    ) async throws -> ViduTask
    
    // Poll task status
    func getTaskStatus(taskID: String) async throws -> ViduTask
    
    // Download result
    func downloadResult(taskID: String, to destination: URL) async throws -> URL
}

struct ViduTask: Codable {
    var taskID: String
    var status: ViduTaskStatus
    var progress: Int           // 0-100
    var resultURL: String?
    var errorMessage: String?
}
```

- Rate limiting: configurable, default 5 concurrent tasks
- Circuit breaker: trips after 5 consecutive failures
- Polling interval: 5 seconds
- Results saved to: `<animateURL>/Animate/shots/<scene-slug>/shot-<index>/vidu-output.mp4`

### 3.7 Vidu Queue (Separate from Gemini and Meshy)

```swift
struct ViduBatchQueueItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var sceneName: String
    var shotIndex: Int
    var firstFramePath: String
    var lastFramePath: String
    var motionPrompt: String
    var durationSeconds: Double
    var aspectRatio: String
    var animationStyle: AnimationStylePreset
    var dateQueued: Date = Date()
}
```

`store.viduQueue: [ViduBatchQueueItem]` — fully independent from geminiQueue and meshyQueue.

Queue controls shown in the Shot Production Strip's Vidu section + optionally in the Inspector when on the Animate page.

### 3.8 Files to Create/Modify

**New files:**
- `Models/ShotProductionModels.swift` — ShotBackgroundPlate, ShotFrameGeneration, AnimationStylePreset, ViduTaskStatus
- `Services/ViduAPIService.swift` — Vidu Q3 API client
- `Views/ShotFilmstripView.swift` — horizontal shot filmstrip
- `Views/ShotProductionStripView.swift` — the main shot production detail strip
- `Views/ShotFrameCard.swift` — first/last frame card component

**Modify:**
- `AnimateModels.swift` — add `animationStylePreset` to `AnimationScene`, add `shotBackgroundPlate` and `shotFrameGeneration` to `AnimationSceneShot`
- `AnimateStore.swift` — add `viduQueue`, `viduAPIKey`, shot production CRUD methods, Vidu task management
- `Animate3DWorkspace.swift` — insert filmstrip + production strip below 3D preview in middle pane
- `AnimateStore.swift` — persistence for shot background plates and frame generations

---

## 4. Inline 3D Model Viewer on Characters Page

### 4.1 Problem

Current "View" button opens model externally via `NSWorkspace.shared.open()`. No inline preview, no texture display, no orbit/zoom.

### 4.2 Solution — SCNView-based Inline Viewer

New `Character3DModelViewer` component using SceneKit, embedded inline in the 3D Models pane.

#### 4.2.1 Layout

```
┌─────────────────────────────────────────────────────────┐
│  ▾ 3D MODEL: Military Costume                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │              3D Model (SCNView)                    │  │
│  │              textured, orbitable                   │  │
│  │              drag=orbit scroll=zoom                │  │
│  │              right-drag=pan                        │  │
│  │                                                   │  │
│  │  [Wireframe] [Textured] [Cel-Shaded] [Fullscreen] │  │
│  └───────────────────────────────────────────────────┘  │
│  File: amira-military.glb  Polys: 98,432  Verts: 51k   │
│  Textures: 3 (diffuse, normal, roughness)               │
└─────────────────────────────────────────────────────────┘
```

#### 4.2.2 Implementation

- `NSViewRepresentable` wrapping `SCNView`
- Model loading:
  - `.usdz` / `.scn` → `SCNScene(url:)` directly
  - `.glb` / `.obj` → `MDLAsset(url:)` via ModelIO → convert to `SCNScene`
- `allowsCameraControl = true` for built-in orbit/zoom/pan
- Three-point lighting: key (warm, 45° above-right), fill (cool, opposite side, 40% intensity), rim (behind, edge highlight)
- Three render modes via segmented control:
  - **Wireframe** — `SCNMaterial.fillMode = .lines`
  - **Textured** — default material rendering with loaded textures
  - **Cel-Shaded** — apply existing `CelShadingTechnique` from project
- Model stats: traverse `SCNGeometry` nodes, sum polygon/vertex counts, enumerate texture attachments
- "Fullscreen" toggle: expands viewer to fill Characters middle pane, collapses other sections
- "View" button in `models3DCostumeRow` toggles the inline viewer open/closed (replaces `NSWorkspace.shared.open`)

#### 4.2.3 Files to Create/Modify

**New:**
- `Views/Character3DModelViewer.swift` — the SCNView wrapper + render mode controls + stats

**Modify:**
- `CharactersPageView.swift` — replace `view3DModel()` with inline viewer toggle, add viewer to `models3DCostumeRow`

---

## 5. Cross-Cutting Concerns

### 5.1 New API Keys in Settings

Add to AnimateStore settings UI:
- `miniMaxAPIKey: String` — MiniMax M2.7 for prompt generation
- `viduAPIKey: String` — Vidu Q3 for video generation

Alongside existing `geminiAPIKey` and `meshyAPIKey`.

### 5.2 Queue Architecture Summary

Three fully independent queues on AnimateStore:

| Queue | Type | Backend | Page |
|-------|------|---------|------|
| `geminiQueue` | Image generation (references, concept art) | Gemini API | Characters |
| `meshyQueue` | 3D model generation | Meshy API | Characters |
| `viduQueue` | Video generation (first→last frame) | Vidu Q3 API | Animate |

Each queue has its own Submit/Clear/Progress UI. No cross-contamination.

### 5.3 Text Field Cursor-Jump Fix (Critical Bug)

#### Problem

Every text field in the Characters page and CharacterReferenceWorkflowSheet suffers from a cursor-jumping bug. When the user types, the cursor resets to the end of the text after every keystroke.

#### Root Cause

Classic SwiftUI `@Observable` re-rendering bug:

1. Text field binding calls a store method (e.g., `store.updateCostumeReferenceSetName()`)
2. Store method mutates `characters` array element
3. `@Observable` publishes the change
4. View re-renders, recalculating computed `character` property
5. ForEach over `costumeReferenceSets` gets new object references
6. SwiftUI loses text field focus → cursor jumps to end

#### Affected Fields

**CharacterReferenceWorkflowSheet.swift:**
- Costume name TextField (line 652)
- Costume notes TextEditor (line 662)
- Costume sheet prompt TextEditor (line 725)
- All inside `ForEach(character.costumeReferenceSets)` (line 642)

**CharactersPageView.swift:**
- Age TextField (line 805)
- Backstory TextEditor via `textEditorRow` (line 830)
- Personality TextEditor via `textEditorRow` (line 838)
- Notes TextEditor via `textEditorRow` (line 846)

#### Fix Strategy — Debounced Local State Pattern

For EVERY text field/editor that writes to the store:

1. Replace direct store-mutating bindings with local `@State` variables
2. Initialize local state from store value on appear
3. Use `.onChange(of: localText)` with debounce (300ms) to write back to store
4. Use `.onChange(of: storeValue)` to update local state ONLY when the source changes externally (different from local value AND not currently focused)

Concrete pattern:
```swift
// BEFORE (broken):
TextField("Name", text: Binding(
    get: { costume.name },
    set: { store.updateCostumeReferenceSetName($0, costumeID: costume.id, for: characterID) }
))

// AFTER (fixed):
@State private var localCostumeName: String = ""

TextField("Name", text: $localCostumeName)
    .onAppear { localCostumeName = costume.name }
    .onChange(of: localCostumeName) { _, newValue in
        // Debounced write-back — does NOT trigger re-render during typing
        store.updateCostumeReferenceSetName(newValue, costumeID: costume.id, for: characterID)
    }
```

For the `textEditorRow` helper in CharactersPageView, refactor it to accept a `Binding<String>` backed by local state in the caller, with the same debounced pattern.

For ForEach-based costume fields in CharacterReferenceWorkflowSheet: extract each costume section into its own `CostumeSectionView` struct with `@State` local copies of name, notes, and sheetPrompt. This isolates each costume's text editing from re-renders of the parent ForEach.

#### Files to Modify

- `CharacterReferenceWorkflowSheet.swift` — extract `CostumeSectionView`, add local state for all text fields
- `CharactersPageView.swift` — refactor `textEditorRow` to use local state, fix age field
- Audit ALL other text fields in the project for the same pattern

### 5.4 Smart Reference Sheet Cropping

#### Problem

Current cropping (`cropReferenceSheetImageData` in AnimateStore.swift:6732) uses a dumb 3x2 grid with 2% inset. It assumes the reference sheet is a perfect grid with no variation. In practice, Gemini-generated reference sheets have:
- Uneven spacing between poses
- Poses that bleed across grid cell boundaries
- Variable amounts of whitespace around each figure
- Text labels and annotations that shouldn't be in the crop
- Figures of different sizes (head close-ups vs full-body)

Results: crops cut off limbs, include pieces of adjacent drawings, have inconsistent whitespace.

#### Fix — Vision-Based Smart Cropping

Replace the dumb grid crop with a multi-step image analysis pipeline:

**Step 1: Connected Component Analysis**
- Convert image to grayscale, threshold to binary (white background vs content)
- Find connected components (contiguous non-white regions)
- Filter out tiny components (noise, dots, text labels < N pixels)
- Result: bounding boxes of each major figure in the sheet

**Step 2: Grid-Guided Assignment**
- Use the expected 3x2 grid as a guide to assign each detected figure to a pose slot
- For each grid cell, find the connected component whose centroid is closest to the cell center
- Handle cases where a figure spans two cells (use the cell with the most overlap)

**Step 3: Tight Crop with Uniform Padding**
- For each assigned figure, compute the tight bounding box from the connected component
- Add uniform padding (configurable, default 5% of cell size) on all sides
- Clamp to image bounds

**Step 4: Adjacent Figure Masking**
- For each crop region, check if any OTHER figure's pixels fall within the padded bounds
- If so, flood-fill those intruding pixels with white (the background color)
- This cleanly removes parts of adjacent drawings that bleed into the crop box

**Step 5: Output**
- Render each cleaned crop as PNG
- Store the actual crop rect used (for the variant's `sourceCropRect`)

#### Implementation

New `ReferenceSheetCropService`:
```swift
class ReferenceSheetCropService {
    struct CropResult {
        let pose: CharacterReferencePose
        let imageData: Data
        let cropRect: CropRect     // normalized
        let confidence: Double     // 0-1, how well the figure was detected
    }
    
    func cropSheet(
        image: NSImage,
        kind: ReferenceSheetCropKind,  // .head or .fullBody
        expectedPoses: [CharacterReferencePose]
    ) -> [CropResult]
}
```

Uses Core Image + Accelerate framework for performant image analysis:
- `CIFilter` for threshold/edge detection
- `vImage` for connected component labeling
- No ML model needed — this is straightforward computer vision

#### Fallback

If the smart crop fails (confidence < 0.3 for any slot), fall back to the current grid-based crop for that slot and log a warning. The user can then manually adjust via the existing `CharacterVariantCropSheet`.

#### Files to Create/Modify

**New:**
- `Services/ReferenceSheetCropService.swift` — the smart cropping pipeline

**Modify:**
- `AnimateStore.swift` — replace `cropReferenceSheetImageData` and `normalizedCropRect` calls with `ReferenceSheetCropService`

---

## 6. Characters Page Audit — Bug Fixes

Comprehensive audit of CharactersPageView, CharacterReferenceWorkflowSheet, Meshy3DGenerationPane, InspectorView, and AnimateStore character methods. All issues below must be fixed.

### 6.1 Critical Bugs

#### 6.1.1 `characterHeader` Never Called — No Character Identity in Detail Pane
**CharactersPageView.swift:620-655**

`characterHeader(_:)` is a full ViewBuilder (profile image, name, color dot, description) that is never inserted into `characterDetail`. The detail pane shows no identification of which character the user is looking at — it starts directly with collapsible sections.

**Fix:** Call `characterHeader(character)` at the top of the `characterDetail` ScrollView content.

#### 6.1.2 `lookDevelopmentSection` Never Called — Dead Summary UI
**CharactersPageView.swift:1039-1079**

`lookDevelopmentSection(_:)` builds stat pills and master sheet preview. Never referenced anywhere.

**Fix:** Add as a collapsible pane in `characterDetail`, between Notes and Inspiration.

#### 6.1.3 `submitInspirationBatch` Unreachable — Batch Mode Silently Broken
**CharactersPageView.swift:1592-1667**

The GeminiGenerationPreflightSheet `.batch` case only calls `store.addToBatchQueue()`. The actual `submitInspirationBatch` function (which submits to GeminiBatchService, launches watchdog, registers job) is never called.

**Fix:** Route the `.batch` case through `submitInspirationBatch` instead of `store.addToBatchQueue`.

#### 6.1.4 ImageCropper "1:1 Square" Produces Non-Square Rectangle
**CharactersPageView.swift:2878-2894**

`makeSquareCrop(for:)` math is inverted — produces a rectangle, not a square, for non-square images.

**Fix:** `let squareSize = min(maxWidth, maxHeight)` and use equal width/height.

#### 6.1.5 `submitBatch()` Dead Code in CharacterReferenceWorkflowSheet
**CharacterReferenceWorkflowSheet.swift:1664-1738**

Complete 74-line function never called. Batch mode falls through to `store.addToBatchQueue()` instead.

**Fix:** Either wire this function into the batch path or remove it and fix the batch flow.

#### 6.1.6 "Generate 1" Button Missing Disabled Check
**CharacterReferenceWorkflowSheet.swift:316-322**

"Generate 1" master sheet button has no `.disabled(store.geminiAPIKey.isEmpty)`. Will proceed with empty API key and fail.

**Fix:** Add `.disabled(store.geminiAPIKey.isEmpty)`.

#### 6.1.7 "Generate Missing" Regenerates ALL When None Are Missing
**CharacterReferenceWorkflowSheet.swift:1243-1244, 1342-1343**

When all slots have approved variants, `slots.isEmpty` triggers fallback to ALL slots. User clicks "Generate Missing" expecting no-op; gets full regeneration.

**Fix:** When `slots.isEmpty`, show a "Nothing to generate" message and return early.

#### 6.1.8 Meshy 3D Downloads Completely Broken — Three Compounding Bugs
**AnimateStore.swift:8618-8674**

Three bugs combine to make Meshy downloads appear to not work at all:

1. **Wrong directory path** (line 8628-8630): Uses `owpSlug` instead of `assetFolderSlug`, and `"Characters"` (capital C) instead of `"characters"`. Files download to a non-standard parallel directory that nothing else references.

2. **No `save()` call** (line 8671-8674): `addModel3D` appends to in-memory array but never persists. Even if files download correctly, the data model forgets them on restart.

3. **Wrong costume name** (line 8644): Hardcoded to `"meshy-\(taskID.prefix(8))"` instead of passing through the actual costume name from the generation request.

**Fix:** 
- Use `character.assetFolderSlug` and lowercase `"characters"` 
- Add `save()` at end of `addModel3D`
- Thread the costume name through from the generation request

#### 6.1.9 `generateMeshy3DModel` Crashes on Empty `imageURLs`
**AnimateStore.swift:8563-8581**

`imageURLs[0]` with no bounds check. Crashes if all images fail to encode, also permanently locks `isGeneratingMeshy3D = true`.

**Fix:** Add `guard !imageURLs.isEmpty` with error message and flag cleanup.

#### 6.1.10 `meshyGeneratingCharacterID` Never Cleared
**AnimateStore.swift:8548-8615**

Set at start of generation, never reset to nil on completion. Causes stale UI state.

**Fix:** Set to nil alongside `isGeneratingMeshy3D = false`.

#### 6.1.11 Stale Index After Async Panel in Import Methods
**AnimateStore.swift:5147-5184, 5412-5441, 5572-5621**

`importInspirationImages`, `importReferenceImages`, `import3DModel` all capture array index before panel open. If characters are reordered while panel is open, files go to wrong character directory.

**Fix:** Re-resolve index by characterID inside the async Task block.

### 6.2 High-Severity Issues

#### 6.2.1 Shared Gallery Selection State Across Sections
**CharactersPageView.swift:12-13**

`selectedGalleryImagePaths` and `lastClickedGalleryImagePath` shared between Inspiration and Animated galleries. Selections cross-contaminate, deletions can affect wrong gallery.

**Fix:** Separate selection state per gallery section.

#### 6.2.2 `InspirationGallerySheet` and `ReferenceImagesSheet` Load NSImage Synchronously
**CharactersPageView.swift:3006-3011, 3291-3297**

Synchronous `NSImage(contentsOf:)` in body — freezes UI with large galleries. Rest of file uses `AsyncThumbnailView`.

**Fix:** Use `AsyncThumbnailView` pattern.

#### 6.2.3 Double-Tap Detection Using `NSApp.currentEvent` Unreliable
**CharactersPageView.swift:2321-2333**

`TapGesture` + `NSApp.currentEvent?.clickCount` fires asynchronously. Double-click detection unreliable.

**Fix:** Use `.onTapGesture(count: 2)` like other locations in the file.

#### 6.2.4 `showInspirationGallery` Never Set to True — Sheet Unreachable
**CharactersPageView.swift:15, 101-109**

State variable exists, sheet modifier exists, but no button ever sets it to true. Dead because `characterHeader` is never called.

**Fix:** Will be fixed when `characterHeader` is restored (6.1.1).

#### 6.2.5 `onMove` Silently Fails During Search
**CharactersPageView.swift:350-355**

Drag-to-reorder returns silently when search is active. User sees animation complete then snap back.

**Fix:** Disable drag affordance when search text is non-empty.

#### 6.2.6 Phantom Approval UI — Auto-Selects Last Variant as "Chosen"
**CharacterReferenceWorkflowSheet.swift:410, 522, 749**

When no explicit approval exists, last variant gets green "Chosen" border. Creates false sense of approval.

**Fix:** Remove auto-selection visual, or persist it to the store on seed.

#### 6.2.7 `try?` Silently Drops Crop Errors
**CharacterReferenceWorkflowSheet.swift:486, 704**

"Re-crop from Sheet" buttons use `try?`. Crop failures are invisible to user.

**Fix:** Use `do/catch` and set `generationError`.

#### 6.2.8 Meshy Batch Loop Reports Success Even When Items Failed
**Meshy3DGenerationPane.swift:355-366**

"Batch complete — N costumes generated" shown unconditionally regardless of failures.

**Fix:** Track per-item status, only show success if all succeeded.

#### 6.2.9 `encodeImages` Blocks Main Thread
**Meshy3DGenerationPane.swift:440-448**

Synchronous `Data(contentsOf:)` on main actor for multiple large images.

**Fix:** Make async, use background task for file I/O.

#### 6.2.10 Meshy `batchQueue` Lost on Pane Collapse
**Meshy3DGenerationPane.swift:22-24**

Local `@State` destroyed when collapsible section collapses. Can leave `store.isGeneratingMeshy3D` permanently true.

**Fix:** Move to store, keyed by character ID. (Already planned in Section 1.)

#### 6.2.11 `handleBatchItemCompletion` No Concurrent Guard
**AnimateStore.swift:8680-8737**

Can race with user-initiated generation, clobbering shared state.

**Fix:** Add `guard !isGeneratingMeshy3D` or serialize via operation queue.

#### 6.2.12 `downloadMeshyAssets` Wrong Slug + Wrong Capitalization
**AnimateStore.swift:8628-8630**

Uses `owpSlug` instead of `assetFolderSlug`, and `"Characters"` instead of `"characters"`. Creates parallel directory trees.

**Fix:** Use `character.assetFolderSlug` and lowercase `"characters"`.

### 6.3 Important Issues

#### 6.3.1 Gallery Selection Not Reset on Character Switch
**CharactersPageView.swift:430**

`selectedGalleryImagePaths` not cleared when `selectedCharacterID` changes. Orphaned selections shown for wrong character.

**Fix:** Add `.onChange(of: store.selectedCharacterID)` to clear selection state.

#### 6.3.2 `textEditorRow` Cursor Jump (All Character Note Fields)
**CharactersPageView.swift:856-873**

Already covered in Section 5.3.

#### 6.3.3 All Costume Text Fields Cursor Jump
**CharacterReferenceWorkflowSheet.swift:652, 662, 725**

Already covered in Section 5.3.

#### 6.3.4 `generationStatus` Not Cleared on Error Path
**CharacterReferenceWorkflowSheet.swift:1646-1649**

After error, status shows "Generating N of M…" with checkmark icon.

**Fix:** Set `generationStatus = nil` in catch block.

#### 6.3.5 Accessory Slots Missing Crop Callbacks
**CharacterReferenceWorkflowSheet.swift:866-913**

`onAdjustCrop` defaults to no-op for accessories. "Adjust Crop" context menu does nothing.

**Fix:** Wire to `store.openVariantCropTool` or hide menu item for accessories.

#### 6.3.6 `ReferenceVariantCard` Store as `let` — No Observation
**CharacterReferenceWorkflowSheet.swift:2017, 2123**

Store captured as `let` in child views, doesn't register @Observable dependencies.

**Fix:** Change to `@Bindable var store`.

#### 6.3.7 Hardcoded `/6` in Head Poses Pill
**CharacterReferenceWorkflowSheet.swift:278**

Should use `character.headTurnaroundSlots.count`.

#### 6.3.8 `updateCharacterBackstory`/`updateCharacterPersonality` Save on Every Keystroke
**AnimateStore.swift:4897-4901, 5058-5062**

Full `save()` on every character typed. Should use `scheduleDebouncedSave()` with change guard.

#### 6.3.9 `seedCharacterReferenceWorkflowIfNeeded` Unconditional Save
**AnimateStore.swift:5657-5703**

Calls `save()` even when nothing changed. Add `didMutate` tracking.

#### 6.3.10 Accessory Key Corruption on Costume Rename
**AnimateStore.swift:6015-6032**

Accessory key reconstruction uses `split(separator: "-").last`, losing multi-word names ("leather-boots" → "boots").

**Fix:** Use stable per-slot identifier for suffix.

#### 6.3.11 sheetBody/inlineBody Duplicated Modifiers
**CharacterReferenceWorkflowSheet.swift:78-121, 138-181**

Sheet/alert logic copy-pasted verbatim. Extract into shared ViewModifier.

#### 6.3.12 `installedPackages(for:)` Reads Filesystem Every Render
**CharactersPageView.swift:1832-1839**

Creates `CharacterPackageLibrary()` and reads disk on every body evaluation.

**Fix:** Cache in store as observable property, refresh on import/delete.

#### 6.3.13 `ForEach(Array(paths.enumerated()), id: \.offset)` — Index as Identity
**CharactersPageView.swift:2168, 2967, 3251**

Uses offset as SwiftUI identity. Causes re-creation of all cells on deletion instead of animation.

**Fix:** Use `id: \.element` or `ForEach(paths, id: \.self)`.

#### 6.3.14 InspectorView Batch Queue No Progress/Error Display
**InspectorView.swift:628-641**

After "Submit All", queue clears immediately with no progress indicator or error feedback.

**Fix:** Add submission progress state and per-group results.

#### 6.3.15 InspectorView Queue Clears Before Async Work Completes
**InspectorView.swift:651-653**

Items lost on crash. Re-queue on failure creates new UUIDs.

**Fix:** Remove items individually as each succeeds. Preserve original item structs on re-queue.

#### 6.3.16 `ProfileImagePickerSheet` Synchronous Thumbnails
**CharactersPageView.swift:2678**

Synchronous `thumbnailImage(for:)` in body. Should use `AsyncThumbnailView`.

#### 6.3.17 `Meshy isGeneratingMeshy3D` Single Global Flag
**Meshy3DGenerationPane.swift:375 / AnimateStore.swift:8546**

Shared across all characters. Character A's generation disables Character B's button with no explanation.

**Fix:** Per-character generation state dictionary. (Addressed in Section 1 queue redesign.)

#### 6.3.18 `textureImageURL` Always First Image Regardless of Pose
**Meshy3DGenerationPane.swift:242-246**

Should explicitly find `.frontNeutral` before falling back to first.

#### 6.3.19 `sanitizedFilenameStem` Doesn't Strip All Unsafe Characters
**CharactersPageView.swift:1724-1731**

Missing colons, quotes, asterisks. Can break filenames.

**Fix:** Strip all non-alphanumeric except hyphens and underscores.

### 6.4 Files Affected by Audit Fixes

- `CharactersPageView.swift` — 16 fixes
- `CharacterReferenceWorkflowSheet.swift` — 11 fixes
- `Meshy3DGenerationPane.swift` — 6 fixes
- `InspectorView.swift` — 3 fixes
- `AnimateStore.swift` — 11 fixes

---

## 7. MiniMax M2.7 Usage

Used for text-only prompt generation (not image generation):
- Draw Things SD prompts from place metadata (Places page)
- Shot background plate prompts from scene direction + place (Animate page)
- First/last frame prompts from character + background + direction (Animate page)
- Motion direction text from scene direction tags (Animate page)

All via `MiniMaxPromptService` with rate limiting and circuit breaker.
