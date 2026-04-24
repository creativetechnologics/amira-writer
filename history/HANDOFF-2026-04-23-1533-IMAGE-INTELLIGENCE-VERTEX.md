# Handoff — 2026-04-23 15:33 PDT — Image Intelligence + Vertex Analysis

## Summary

- Implemented the durable image intelligence subsystem in Amira Writer / Opera.
- Added a dedicated AI inspector tab inside **All Project Images**.
- Added queue visibility, per-image runs/jobs, recent logs, returned analysis data, and text search to that inspector tab.
- Added **Vertex AI** as an image-analysis backend alongside the existing AI Studio / Developer API path.
- Built and deployed the app bundle to:
  - `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

## What Shipped

### Image Intelligence backend

- Separate image-analysis credential already exists:
  - `imageAnalysisGeminiAPIKey`
- Separate local SQLite store exists at:
  - `.novotro/image-intelligence.sqlite`
- Image analysis supports:
  - visual analysis
  - image embeddings
  - semantic embeddings
  - persisted jobs/runs
  - backfill
  - search

### New Vertex support for image analysis

- Added backend selection for image analysis:
  - `AI Studio`
  - `Vertex AI`
- Added Vertex image-analysis client:
  - `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/VertexImageAnalysisClient.swift`
- Added image-analysis backend store:
  - `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackendStore.swift`
- Coordinator now chooses backend at runtime.
- Settings UI now lets the user set:
  - Vertex project ID
  - Vertex region
- Vertex auth uses the existing `gcloud auth application-default print-access-token` pattern.

## UI Added

### All Images inspector → AI tab

Location:
- `Packages/Animate/Sources/AnimateUI/AllProjectImagesWorkspace.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AllProjectImagesPageView.swift`

The AI tab now shows:

- selected image status
- analysis record basics
- per-image jobs
- per-image runs
- global queue snapshot
- recent logs
- returned analysis data
- raw model JSON
- text search against stored analysis
- actions:
  - Reanalyze
  - Backfill All
  - Dry Run
  - Start Worker
  - Stop Worker

## Key Files Changed

- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- `Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift`
- `Packages/Animate/Sources/AnimateUI/AllProjectImagesWorkspace.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AllProjectImagesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ProjectCredentialStore.swift`
- `Packages/ProjectKit/Sources/ProjectKit/ProjectPaths.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageIntelligenceStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAssetInspector.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAssetDiscoveryService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackfillService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/GeminiImageAnalysisService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisCoordinator.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageSearchService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/ImageAnalysisBackendStore.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/VertexImageAnalysisClient.swift`

## Tests / Verification

- `swift build --target AnimateUI` passed
- `swift test --filter ImageIntelligence` passed
- `./Scripts/build-app.sh` passed

App bundle installed to:
- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

## Important Notes

- The image-analysis backend is now independent from the image-generation backend.
- The old constraint "do not build" was session-specific and is no longer applicable.
- Vertex model availability was confirmed by the user and supported by the implementation path added here.

## Remaining Nice-to-Haves

Not required for current functionality, but good next steps:

1. Auto-refresh the AI inspector tab every few seconds while the worker is running.
2. Add image-grid badges for `pending / analyzed / failed`.
3. Add explicit retry / clear-failed-job controls.
4. Add a more structured rendering of returned metadata instead of mostly raw JSON blocks.

## How To Use Vertex Analysis

1. Open the app.
2. Open **API Settings**.
3. Go to **Image Analysis**.
4. Select **Vertex AI**.
5. Enter Vertex project ID and region.
6. Ensure terminal auth is ready:
   - `gcloud auth application-default login`
7. Go to **All Images**.
8. Select an image.
9. Open the **AI** inspector tab.
10. Click **Reanalyze** or **Backfill All**, then **Start Worker**.
