# Meshy 3D Generation Pipeline + Crop Tool + Settings

**Date:** 2026-04-02
**Status:** Approved

## Overview

Add a crop adjustment tool to the existing character reference workflow, a new inline collapsible section for Meshy.ai 3D model generation, and a unified API settings sheet. Also fix laptop layout overflow on the character page.

## 1. Crop Adjustment (inside Reference Workflow)

**Location:** Within `CharacterReferenceWorkflowSheet` (already inline in `CharactersPageView`)

**Behavior:**
- Each pose thumbnail in the reference workflow gets a small crop-adjust button (crop icon overlay or context menu item)
- Clicking opens an inline crop editor that shows the **full uncropped source image** with the current crop region overlaid as a draggable, resizable rectangle
- User drags to reposition, uses corner/edge handles to resize the crop region
- "Apply" confirms the crop and updates the stored cropped image
- "Reset" restores the original auto-crop
- The crop editor replaces the thumbnail area temporarily (no pop-out)

**Storage:**
- Crop rectangles stored per-pose as normalized coordinates (0-1 range) so they're resolution-independent
- When a crop is adjusted, the cropped image is re-generated from the source and saved alongside the original

## 2. Meshy 3D Generation Section (new collapsible pane)

**Location:** New `collapsiblePane` in `CharactersPageView.characterDetail`, inserted between "Character Reference Workflow" and "Animated Images" panes.

**AppStorage key:** `charactersPage.showMeshy3DGenerationPane`
**Default collapsed:** true (expanded once user has reference images)

### 2.1 Image Selection

- Auto-selects up to 4 pose images from the reference workflow: front neutral (primary), left profile, right profile, back
- Shows thumbnails of selected images in a horizontal row
- User can click a thumbnail to swap it with another available pose image
- Minimum 1 image required (front neutral), up to 4 supported by Multi Image to 3D API
- Falls back to single Image to 3D endpoint if only 1 image selected

### 2.2 Configuration Panel

| Parameter | Control | Default | Notes |
|-----------|---------|---------|-------|
| Target Polycount | Stepper/text field | 100,000 | Range: 100 - 300,000 |
| Topology | Picker | Triangle | Triangle or Quad |
| Texture | Toggle | On | If off, mesh only (saves 10 credits) |
| Texture Source | Auto | Front neutral image | Uses `texture_image_url` with the front pose |
| Remove Lighting | Toggle | On | Strips highlights/shadows for cleaner base color |
| Enable PBR | Toggle | Off | Generates metallic, roughness, normal maps |
| Output Formats | Multi-select | GLB, USDZ | Options: GLB, FBX, OBJ, STL, USDZ |
| AI Model | Picker | Latest | meshy-5, meshy-6, latest |
| Symmetry | Picker | Auto | Off, Auto, On |

### 2.3 Generation Flow

1. User clicks "Generate 3D Model" button
2. Images are base64-encoded and sent to `POST /openapi/v1/multi-image-to-3d` (or `/image-to-3d` for single image)
3. Task ID returned, polling begins via `GET /openapi/v1/multi-image-to-3d/{id}` every 5 seconds
4. Inline progress bar + status label shows: PENDING -> IN_PROGRESS (with %) -> SUCCEEDED/FAILED
5. On SUCCEEDED: all requested format files auto-download to character's asset directory
6. Downloaded models added to the character's `models3D` array
7. On FAILED: error message displayed inline with retry button

### 2.4 Credits Display

- Before sending, show estimated credit cost (20 no-texture / 30 with texture for meshy-6)
- After Meshy API key is configured, show current balance via `GET /openapi/v1/balance`

## 3. Meshy API Service Layer

### 3.1 MeshyCredentialStore

**File:** `Services/MeshyCredentialStore.swift`
**Pattern:** Mirrors `GeminiCredentialStore` exactly
- Keychain service: `com.amira.writer.animate`
- Keychain account: `meshy-api-key`
- `save(_:)`, `load()`, `delete()` methods

### 3.2 MeshyService

**File:** `Services/MeshyService.swift`

```
class MeshyService {
    static let baseURL = "https://api.meshy.ai/openapi/v1"

    // Core methods
    func createMultiImageTo3D(request: MeshyMultiImageRequest) async throws -> String  // returns task ID
    func createImageTo3D(request: MeshyImageRequest) async throws -> String             // single image fallback
    func getTaskStatus(endpoint: String, taskID: String) async throws -> MeshyTaskResponse
    func pollUntilComplete(endpoint: String, taskID: String, onProgress: (MeshyTaskResponse) -> Void) async throws -> MeshyTaskResponse
    func downloadAsset(from url: URL, to destination: URL) async throws
    func checkBalance() async throws -> Int

    // Auth
    var apiKey: String  // loaded from MeshyCredentialStore
}
```

### 3.3 Models

**File:** `Models/MeshyModels.swift`

```swift
struct MeshyMultiImageRequest: Encodable {
    let imageURLs: [String]          // base64 data URIs or public URLs
    var aiModel: String = "latest"
    var topology: String = "triangle"
    var targetPolycount: Int = 100_000
    var shouldRemesh: Bool = true
    var shouldTexture: Bool = true
    var enablePBR: Bool = false
    var removeLighting: Bool = true
    var textureImageURL: String?      // front neutral image for texturing
    var targetFormats: [String] = ["glb", "usdz"]
    var symmetryMode: String = "auto"
}

struct MeshyTaskResponse: Decodable {
    let id: String
    let status: MeshyTaskStatus      // PENDING, IN_PROGRESS, SUCCEEDED, FAILED, CANCELED
    let progress: Int
    let modelURLs: [String: String]?  // format -> download URL
    let thumbnailURL: String?
    let textureURLs: [MeshyTextureSet]?
    let taskError: MeshyTaskError?
    let createdAt: Int64
    let finishedAt: Int64
}

enum MeshyTaskStatus: String, Decodable {
    case pending = "PENDING"
    case inProgress = "IN_PROGRESS"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}
```

## 4. Unified API Settings Sheet

**Rename:** `GeminiSettingsSheet` -> `APISettingsSheet`
**Location:** Same trigger points, but now contains sections for both services

### Layout

```
API Settings
├── Gemini
│   ├── API Key field (SecureField)
│   ├── Model picker (flash/pro)
│   └── Status indicator (key valid/invalid)
├── Meshy
│   ├── API Key field (SecureField)
│   ├── Balance display (auto-fetched)
│   └── Status indicator (key valid/invalid)
└── Done button
```

Existing references to `GeminiSettingsSheet` throughout the app updated to open `APISettingsSheet`.

## 5. Laptop Layout Fix

**Problem:** Character page buttons/controls overflow on smaller laptop screens.

**Fixes:**
- Audit all `collapsiblePane` trailing button clusters for hard-coded widths
- Ensure trailing buttons wrap or use compact representations on narrow widths
- Check `GeometryReader` constraints in `characterDetail` for minimum width assumptions
- Verify `ScrollView` properly clips and scrolls all content
- Test at 1280px width (13" MacBook)

## 6. Asset Storage

Downloaded 3D models stored in the character's asset directory:
```
Animate/Characters/{characterSlug}/3d-models/{taskID}/
├── model.glb
├── model.usdz
├── model.fbx (if requested)
├── model.obj (if requested)
├── thumbnail.png
└── metadata.json  (Meshy task response for provenance)
```

The `metadata.json` preserves the full Meshy response so we know generation parameters, timestamps, and can re-download if needed (within 3-day retention window).

Character's `models3D` array updated with a new `Character3DModel` entry pointing to the downloaded files.

## 7. Testing

- Unit tests for `MeshyService` request encoding (correct JSON field names, snake_case mapping)
- Unit tests for `MeshyTaskResponse` decoding from sample JSON
- Unit tests for `MeshyCredentialStore` save/load/delete cycle
- Mock-based test for the polling loop (simulated PENDING -> IN_PROGRESS -> SUCCEEDED sequence)
- No live API calls in tests (no API key available yet)

## 8. Files to Create

| File | Purpose |
|------|---------|
| `Services/MeshyService.swift` | API client |
| `Services/MeshyCredentialStore.swift` | Keychain storage |
| `Models/MeshyModels.swift` | Request/response types |
| `Views/Meshy3DGenerationPane.swift` | The new collapsible section content |
| `Views/CropAdjustmentView.swift` | Crop overlay editor |

## 9. Files to Modify

| File | Change |
|------|--------|
| `CharactersPageView.swift` | Add Meshy 3D Generation collapsible pane, add AppStorage toggle |
| `CharacterReferenceWorkflowSheet.swift` | Add crop-adjust button to pose thumbnails |
| `GeminiSettingsSheet.swift` | Rename to `APISettingsSheet`, add Meshy section |
| `AnimateStore.swift` | Add Meshy-related state (apiKey, generation status) |
| `AnimateModels.swift` | Ensure `Character3DModel` supports Meshy asset paths |
| `Package.swift` (Animate) | No new dependencies needed — URLSession only |

## 10. What This Does NOT Cover

- Nano Banana image generation (separate system, not Meshy)
- Background generation (separate system, not Meshy)
- 3D animation pipeline (another agent is working on this)
- Rigging or animation of generated models
