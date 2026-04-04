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

### 5.4 MiniMax M2.7 Usage

Used for text-only prompt generation (not image generation):
- Draw Things SD prompts from place metadata (Places page)
- Shot background plate prompts from scene direction + place (Animate page)
- First/last frame prompts from character + background + direction (Animate page)
- Motion direction text from scene direction tags (Animate page)

All via `MiniMaxPromptService` with rate limiting and circuit breaker.
