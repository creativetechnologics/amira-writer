# Image Intelligence Subsystem

## Overview

The Image Intelligence subsystem analyzes images in the Amira Writer / Opera app using Google's Gemini API. It provides:

- Visual analysis (tags, captions, scene description)
- Vector embeddings for similarity search
- Persistent SQLite storage
- Background job processing
- Reference image selection for scene shots

## Architecture

### Core Components

1. **ImageIntelligenceStore** - Actor-isolated SQLite database
   - Location: `.novotro/image-intelligence.sqlite`
   - Tables: image_assets, image_asset_links, image_analysis_runs, image_visual_metadata, image_tags, image_tag_assignments, image_embeddings, image_analysis_jobs, image_qc_flags

2. **GeminiImageAnalysisService** / **VertexImageAnalysisClient** - REST API clients
   - Base URL: `https://generativelanguage.googleapis.com`
   - Vertex Base URL: `https://aiplatform.googleapis.com`
   - Visual model: `gemini-3-flash-preview`
   - Embedding model: `gemini-embedding-2`
   - Separate API key from image generation
   - Vertex auth uses `gcloud auth application-default print-access-token`; common GUI-safe paths include `~/google-cloud-sdk/bin/gcloud`

3. **ImageAnalysisCoordinator** - Job queue and worker
   - Persistent SQLite-backed queue
   - Exponential backoff on failure
   - Configurable concurrency (default: 1)

4. **ImageAssetDiscoveryService** - Scans project for images
   - Discovers from: places, characters, scene shots, canvas
   - Maps to canonical link kinds

5. **ImageAnalysisBackfillService** - Bulk registration
   - Dry-run support
   - Batch size limits
   - Resume capability

6. **ImageSearchService** - Query and retrieval
   - Tag search
   - Text search
   - Vector similarity search
   - Shot-based reference selection

### Data Flow

```
Generated image save → registerImageAsset(analysisMode: .immediate)
                                      ↓
                                ImageIntelligenceStore
                                      ↓
                         ImageAnalysisCoordinator.analyzeAssetNow()
                                      ↓
                       Gemini / Vertex visual analysis + embeddings
                                      ↓
                                Store Results

Imported/manual reference save → registerImageAsset(analysisMode: .enqueue)
                                      ↓
                           durable queue job for explicit worker runs
```

## Configuration

### API Key

Set in Settings → Image Analysis tab:
- Separate from image generation key
- Uses `imageAnalysisGeminiAPIKey` field in `ProjectCredentialStore`
- Environment fallback: `IMAGE_ANALYSIS_GEMINI_API_KEY`

### Database

Auto-created at `<project>/.novotro/image-intelligence.sqlite`
- WAL mode enabled
- Foreign keys enforced
- Isolated from existing `project.sqlite`

## Usage

### Automatic Registration

Images are automatically registered when saved through these methods:
- `storeGeneratedInspirationImage(...)`
- `storeGeneratedPlaceImage(...)`
- `saveGeneratedImage(...)` (Imagine)
- `appendCanvasGeneration(...)`
- `importReferenceImages(...)`

### Manual Backfill

```swift
// Dry run to see what would be processed
store.runImageIntelligenceBackfill(dryRun: true) { report in
    print(report.summary)
}

// Actual backfill
store.runImageIntelligenceBackfill(dryRun: false) { report in
    print("Registered \(report.newlyRegistered) assets")
}
```

### Worker Control

```swift
store.startImageAnalysisWorker()
// ... later ...
store.stopImageAnalysisWorker()
```

### Headless Vertex Smoke Test

Analyze exactly one existing project image without draining the persistent batch queue:

```bash
.build/debug/Animate --image-intelligence-smoke \
  --project "/path/to/Amira - A Modern Opera" \
  --image "/path/to/existing-project-image.png" \
  --max-spend 1.00
```

The smoke test persists visual metadata, retrieval tags, tag assignments, and two embeddings for the selected image, then writes:

```text
<project>/Animate/ImageIntelligenceSmokeTests/image_intelligence_smoke_latest.json
```

### Search

```swift
let searchService = ImageSearchService(store: imageIntelligenceStore)

// By tags
let results = try await searchService.searchByTags(tags: ["outdoor", "character"])

// Similar images
let similar = try await searchService.findSimilarImages(toAssetID: "asset-uuid")

// For shot
let references = try await searchService.selectForShot(
    input: SelectorInput(
        sceneID: sceneUUID,
        shotID: shotUUID,
        characterIDs: [charUUID],
        placeID: placeUUID
    )
)
```

## Testing

Run tests:
```bash
swift test --filter ImageIntelligence
```

Test files:
- `ImageIntelligenceCredentialTests.swift` - Phase 1: Credentials
- `ImageIntelligenceStoreTests.swift` - Phase 2: Storage
- `ImageIntelligencePhase3Tests.swift` - Phase 3: Discovery
- `GeminiImageAnalysisServiceTests.swift` - Phase 4: API client

## Implementation Phases

All phases are complete:

1. ✅ Foundation and Settings (credentials, paths)
2. ✅ Image Intelligence Store (SQLite schema, registration)
3. ✅ Discovery and Backfill (scanning, dry-run)
4. ✅ Gemini Analysis Client (REST API, embeddings)
5. ✅ Queue and Worker (jobs, stages, backoff)
6. ✅ Live Persistence Hooks (AnimateStore integration)
7. ✅ Search and Selector (tag, text, vector, shot selection)
8. ✅ Status Surfaces (settings UI)
9. ✅ Documentation (this file)

## Constraints

- Supports AI Studio and Vertex AI backends
- Separate API key from image generation
- Does not overwrite manual curation fields
- Does not use XMP/generation sidecars as primary source
- Local SQLite only (no external vector DB)
- No third-party Swift packages added
- Newly generated images run Image Intelligence immediately in a detached
  background task; imported/manual references remain queued for explicit worker
  runs.

## Future Enhancements

- Real-time status indicators in image grids
- Batch reanalysis UI
- Advanced filtering in selector
- Export analysis data
- Integration with prompt builder agent
