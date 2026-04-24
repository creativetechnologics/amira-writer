# Image Intelligence Master Plan

## Status

- **Phase 1-9: IMPLEMENTED** (2026-04-23)
- All core functionality is in place and compiles successfully
- The subsystem is ready for testing and incremental refinement
- Do not run `Scripts/build-app.sh` or deploy unless Gary explicitly requests it
- Prefer targeted unit tests and narrow compile/test loops while refining

## Why This Plan Replaces The Generic Prompt

- The generic prompt assumes a single central image-asset model, a generic background-job system, and a ready-made vector index.
- This repo does not currently have those things.
- The live image system is concentrated in `Packages/Animate/Sources/AnimateUI` and is built around project-local files plus JSON sidecars.
- Gemini image generation already has an `AI Studio` vs `Vertex AI` backend switch. The new analysis pipeline must not be coupled to that switch.
- There is no existing vector-search subsystem in the app code, so the plan must define one.

## Official Doc Confirmations

These were re-checked against current Google docs while preparing this plan.

- Gemini Developer API keys are managed in Google AI Studio and can be supplied explicitly with `x-goog-api-key` against `generativelanguage.googleapis.com`.
- `gemini-embedding-2` supports multimodal embeddings, defaults to 3072 dimensions, and recommends 768, 1536, or 3072 when truncating.
- `gemini-embedding-2` embeddings are incompatible across models and dimensions.
- `gemini-embedding-2` does not use `task_type`; task intent should be expressed in the input text itself.
- `gemini-embedding-2` can aggregate multiple inputs into one embedding, so the implementation must send exactly one image or one text document per stored vector.
- `gemini-3.1-flash-image-preview` supports up to 14 total reference images, with current docs calling out up to 4 character references and up to 10 object references.
- Gemini 3 supports `thinking_level` values including `minimal` and `low`.
- Current Gemini 3 docs note that `media_resolution` is only available in the `v1alpha` API. Phase 1 should not depend on it.

## Repo Snapshot

### Canonical UI / model area

- Primary implementation area: `Packages/Animate/Sources/AnimateUI`
- Shared project paths and SQLite helpers: `Packages/ProjectKit/Sources/ProjectKit`

### Existing image surfaces

| Surface | Current model / storage | Key files |
| --- | --- | --- |
| Places generated images | `GeneratedBackgroundLibraryRecord` inside `PlacesWorkflowLibrary`, persisted to `Places/places-workflow.json` | `AnimateModels.swift`, `AnimateStore.swift` |
| Places metadata / curation | `rating`, `isRejected`, `rejectionNotes`, `draftEditNotes`, `qaFlags`, `canonStatus`, `linkedPlaceID`, `worldNodeID`, `routeID` | `AnimateModels.swift`, `AnimateStore.swift` |
| Place reference images | `PlaceReferenceImage`, `BackgroundPlate.referenceImages`, landmark refs, world nodes | `AnimateModels.swift`, `PlacesPageView.swift` |
| Character images | Many `AnimationCharacter` path arrays and approved variant IDs | `AnimateModels.swift`, `AnimateStore.swift` |
| Scene-shot images | `ImagineSceneShotGallery` with `beginning`, `middle`, `end` paths | `ImagineModels.swift`, `ImagineProjectStorage.swift`, `ImagineScenesPageView.swift` |
| Canvas images | `AnimateStore.CanvasGeneration`, persisted separately in Canvas storage | `AnimateStore.swift`, `ImagineCanvasPageView.swift` |
| All-images aggregation | Ephemeral `ProjectImageRecord` built by scanning the above sources | `AllProjectImagesWorkspace.swift`, `AllProjectImagesPageView.swift` |

### Existing per-image sidecars

- Generation metadata sidecar: `*.json`
- Review metadata sidecar: `*.xmp`
- Scene-shot DrawThings prompt sidecar: `*.prompt.txt`

Relevant code:

- Generation metadata writer / reader: `AnimateStore.writeGenerationMetadata(...)` and `AnimateStore.generationMetadata(for:)`
- XMP review sidecar reader / writer: `ImageLibraryMetadataSidecarService`

### Existing settings and secret storage

- Project-local credentials live in `Settings/api-credentials.json`
- Current credential store: `ProjectCredentialStore`
- Current Gemini generation key field: `geminiAPIKey`
- Existing Gemini generation settings UI: `Views/GeminiSettingsSheet.swift`

### Existing Gemini generation split

- Current image generation service: `Services/GeminiImageService.swift`
- Existing backend switch: `ImageGenBackendStore` with `.aiStudio` and `.vertex`
- Existing Vertex client: `Services/VertexAIClient.swift`

This existing generation path must remain intact. The analysis pipeline must not call into it.

### Existing scene and reference context already available in app models

- `AnimationScene`
- `AnimationSceneShot`
- `SceneDirectionTemplate`
- `SceneShotPreset`
- `AnimationCharacter`
- `BackgroundPlate`
- `PlaceReferenceImage`
- `PlaceWorldNode`
- `PlaceContinuityReview`
- `PlacesScriptIndexService`

Those models are the future selector's source context. The plan should use them instead of inventing parallel scene / shot / character concepts.

### Existing tests worth following

- `Packages/Animate/Tests/AnimateTests/PlacesPersistenceTests.swift`
- `Packages/ProjectKit/Tests/ProjectKitTests/ProjectDatabaseTests.swift`
- `Packages/Animate/Tests/AnimateTests/ImagineModelsTests.swift`

These show the repo's current testing style and fixture patterns.

## Non-Negotiable Constraints

- Use Gemini Developer API / Google AI Studio auth for image analysis.
- Do not use Vertex AI for image analysis.
- Do not route analysis through `GeminiImageService`.
- Do not read analysis credentials from Vertex settings.
- Do not overwrite or repurpose existing manual review fields like place ratings, rejection flags, canon status, or character inspiration review state.
- Do not make XMP or generation sidecars the primary source of truth.
- Do not introduce a remote vector database or hosted dependency for the first implementation.
- Do not add third-party Swift packages unless Gary later approves it.
- Do not refactor unrelated generation code while landing this feature.

## Repo-Specific Architecture Decisions

### 1. Introduce a canonical image asset registry first

There is no single global image model today. The first durable step is to create one.

Use one canonical asset row per resolved image file, plus link rows back to domain objects.

Why:

- The same file can appear in multiple app surfaces.
- Paths alone are not enough for queueing, dedupe, provenance, or reanalysis.
- Future search and selector code needs a single lookup key.

### 2. Use a dedicated project-local SQLite store for image intelligence

Preferred initial location:

- `.novotro/image-intelligence.sqlite`

Implementation detail:

- Add a new path helper in `ProjectPaths`, such as `imageIntelligenceSQLite`.

Why this is the best fit for this repo:

- The app already uses SQLite under `.novotro/` for project-local indexing.
- This isolates image-intelligence schema and migration risk from the existing `ProjectDatabase` schema.
- It avoids wedging analysis state into `Places/places-workflow.json` or character JSON payloads.

Important pre-implementation check:

- If Gary's sync setup does not replicate `.novotro/`, move the DB path to `Settings/image-intelligence.sqlite` before code lands.
- Do not split the same subsystem across two storage locations.

### 3. Start with SQLite-backed vector storage plus in-process similarity search

Do not add pgvector, Qdrant, Pinecone, Weaviate, LanceDB, or any external index in phase 1.

Use:

- SQLite tables for vectors and metadata
- float32 BLOB storage for vectors
- stored norm per vector
- filtered candidate fetch plus cosine similarity in Swift

Why:

- The target scale is in the thousands of images, not millions.
- The repo has no existing vector database infrastructure.
- An isolated local solution is safer for lower-cost agents to implement correctly.

### 4. Build a persisted queue, not an in-memory queue

The app has in-memory queues and several persisted batch-job manifests, but it does not have a generic durable worker queue.

Therefore:

- Do not reuse `geminiQueue`, `viduQueue`, or `batchProcessingQueue`.
- Add a small persisted queue table inside the image-intelligence SQLite store.
- Run the worker while the project is open.
- Resume pending work on reopen.

### 5. Keep analysis additive to existing manual curation systems

Existing curated fields already matter for production image selection.

The new subsystem must read and respect:

- `GeneratedBackgroundLibraryRecord.rating`
- `GeneratedBackgroundLibraryRecord.isRejected`
- `GeneratedBackgroundLibraryRecord.canonStatus`
- `GeneratedBackgroundLibraryRecord.qaFlags`
- character inspiration ratings / rejected paths / curated paths
- XMP review sidecars
- approved place / node / sheet image pointers already stored in models

Do not replace those with Gemini output.

### 6. Keep the scene-shot naming aligned with this repo

The generic prompt talks about `start_frame` and `end_frame`.

This repo already uses:

- `ImagineShotMoment.beginning`
- `ImagineShotMoment.middle`
- `ImagineShotMoment.end`

Use existing names internally.

Mapping rule:

- `start_frame` maps to `beginning`
- `end_frame` maps to `end`
- general continuity / neutral retrieval can use `middle` or a separate generic query mode

## Proposed New Folder / File Layout

Add a new service area under `Packages/Animate/Sources/AnimateUI/Services/ImageIntelligence/`.

Suggested files:

- `ImageIntelligenceModels.swift`
- `ImageIntelligenceStore.swift`
- `ImageAssetDiscoveryService.swift`
- `ImageAssetRegistrar.swift`
- `ImageAnalysisSchema.swift`
- `GeminiImageAnalysisService.swift`
- `ImageAnalysisQueueService.swift`
- `ImageAnalysisCoordinator.swift`
- `ImageAnalysisBackfillService.swift`
- `ImageSearchService.swift`
- `ReferenceImageSelector.swift`
- `ImageAnalysisLogging.swift`

Files expected to be edited outside that folder:

- `Packages/ProjectKit/Sources/ProjectKit/ProjectPaths.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ProjectCredentialStore.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- `Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift`
- `Packages/Animate/Sources/AnimateUI/AllProjectImagesWorkspace.swift`
- `Packages/Animate/Sources/AnimateUI/Views/AllProjectImagesPageView.swift`

## Canonical Data Model

### New top-level concept: image asset

Each image asset represents one actual image file on disk.

Recommended `image_assets` fields:

- `id`
- `resolved_path`
- `project_relative_path`
- `filename`
- `mime_type`
- `width`
- `height`
- `aspect_ratio`
- `file_size_bytes`
- `content_hash_sha256`
- `perceptual_hash`
- `created_at`
- `updated_at`
- `last_seen_at`
- `is_missing`
- `generation_prompt`
- `generation_model`
- `generation_aspect_ratio`
- `generation_image_size`
- `generation_source_json`

Notes:

- `generation_*` fields are optional convenience columns populated from existing sidecars.
- The full raw generation sidecar should still be captured in `generation_source_json` when available.

### New link table: image asset links

One image can belong to several app concepts. Capture that explicitly.

Recommended `image_asset_links` fields:

- `id`
- `image_asset_id`
- `link_kind`
- `owner_id`
- `owner_parent_id`
- `moment`
- `workflow`
- `context_json`
- `created_at`
- `updated_at`

Recommended initial `link_kind` values:

- `place_generated`
- `place_reference`
- `place_landmark_reference`
- `place_angle_image`
- `place_master_map`
- `map3d_capture`
- `character_profile`
- `character_inspiration`
- `character_reference`
- `character_animated`
- `character_master_source`
- `character_master_sheet_variant`
- `character_head_sheet_variant`
- `character_lookdev_variant`
- `character_head_turn_variant`
- `character_costume_sheet_variant`
- `character_costume_fullbody_variant`
- `character_costume_accessory_variant`
- `character_costume_reference`
- `character_costume_variation`
- `scene_shot_image`
- `canvas_generation`

Optional later:

- `character_action_pose`
- `archived_prior_version`

### Analysis runs

Use one row per analyzed version / configuration.

Recommended `image_analysis_runs` fields:

- `id`
- `image_asset_id`
- `source_content_hash`
- `reason`
- `status`
- `local_inspection_status`
- `visual_analysis_status`
- `image_embedding_status`
- `semantic_embedding_status`
- `tag_normalization_status`
- `visual_model_id`
- `embedding_model_id`
- `embedding_dimension`
- `analysis_schema_version`
- `analysis_prompt_version`
- `tag_taxonomy_version`
- `started_at`
- `completed_at`
- `retry_count`
- `error_code`
- `error_message`
- `created_at`
- `updated_at`

### Current canonical visual metadata

Recommended `image_visual_metadata` fields:

- `id`
- `image_asset_id`
- `analysis_run_id`
- `schema_version`
- `summary`
- `short_caption`
- `long_caption`
- `asset_roles_json`
- `entities_json`
- `scene_json`
- `camera_json`
- `style_json`
- `quality_json`
- `retrieval_json`
- `confidence_json`
- `raw_model_json`
- `model_id`
- `created_at`
- `updated_at`

### Tag tables

Recommended `image_tags` fields:

- `id`
- `slug`
- `display_name`
- `category`
- `parent_tag_id`
- `created_at`
- `updated_at`

Recommended `image_tag_assignments` fields:

- `id`
- `image_asset_id`
- `tag_id`
- `analysis_run_id`
- `source`
- `confidence`
- `is_negative`
- `created_at`
- `updated_at`

### Embeddings

Recommended `image_embeddings` fields:

- `id`
- `image_asset_id`
- `analysis_run_id`
- `embedding_kind`
- `model_id`
- `embedding_dimension`
- `vector_blob`
- `vector_norm`
- `content_hash`
- `source_text`
- `created_at`
- `updated_at`

Recommended `embedding_kind` values:

- `image_visual`
- `semantic_metadata`
- `generation_prompt`
- `shot_query`

Storage rule:

- Store vectors as float32 little-endian BLOBs, not JSON arrays.

### Queue jobs

Recommended `image_analysis_jobs` fields:

- `id`
- `image_asset_id`
- `dedupe_key`
- `reason`
- `status`
- `priority`
- `attempt_count`
- `max_attempts`
- `available_at`
- `started_at`
- `finished_at`
- `last_error_code`
- `last_error_message`
- `created_at`
- `updated_at`

### QC flags

Recommended `image_qc_flags` fields:

- `id`
- `image_asset_id`
- `analysis_run_id`
- `flag_type`
- `severity`
- `score`
- `reason`
- `related_scene_id`
- `related_shot_id`
- `related_place_id`
- `related_character_id`
- `created_by`
- `created_at`
- `resolved_at`

## Canonical Discovery Scope

### Sources that phase 1 must register and backfill

- `placesWorkflowLibrary.generatedImageRecords`
- `BackgroundPlate.imagePaths`
- `BackgroundPlate.animatedImagePaths`
- `BackgroundPlate.referenceImages`
- `PlacesWorkflowLibrary.landmarkReferences`
- `PlacesWorkflowLibrary.masterMapImagePath`
- `PlaceWorldNode.approvedPhotorealImagePath`
- `PlaceWorldNode.approvedAnimatedImagePath`
- all character image-path fields already surfaced in `AllProjectImagesWorkspace`
- `ImagineSceneShotGallery.beginningImagePaths`
- `ImagineSceneShotGallery.middleImagePaths`
- `ImagineSceneShotGallery.endImagePaths`
- `canvasGenerations`

### Sources to include if practical in phase 1, otherwise phase 2

- prior generated-place versions from `GeneratedBackgroundLibraryRecord.priorVersions`
- action-pose images from `ActionImageService`
- any image folders that exist on disk but are not currently referenced by a live model

### Best existing discovery helper

Use `AllProjectImagesWorkspace.buildRecordSeeds(...)` as the initial checklist of what the app considers image inventory today.

Do not copy its ephemeral model as the durable store.

## Gemini API Contract For This Repo

### Settings and credential rules

Add a new separate credential field in `ProjectCredentialStore.Payload`:

- `imageAnalysisGeminiAPIKey`

Expose it with dedicated accessors:

- `imageAnalysisGeminiAPIKey()`
- `setImageAnalysisGeminiAPIKey(_:)`

Runtime lookup order:

1. project-local `imageAnalysisGeminiAPIKey`
2. environment fallback `IMAGE_ANALYSIS_GEMINI_API_KEY`

Do not fall back to:

- `geminiAPIKey`
- Vertex project or region
- `GOOGLE_APPLICATION_CREDENTIALS`

### Client implementation choice

Use `URLSession` REST calls, not a new SDK dependency.

Why:

- Existing generation service already uses `URLSession`.
- Lower-cost agents are less likely to destabilize the package graph.
- The required requests are straightforward.

### New client

Create a separate service, for example:

- `GeminiImageAnalysisService`

Do not extend `GeminiImageService` unless Gary later asks for consolidation after review.

### Base URL

- `https://generativelanguage.googleapis.com`

### Visual analysis model

- `gemini-3-flash-preview`

### Embedding model

- `gemini-embedding-2`

### Image generation model remains downstream only

- `gemini-3.1-flash-image-preview`

### Structured output strategy

This is Swift, not TypeScript.

Implementation guidance:

- Define a strongly typed `Codable` response model in Swift.
- Define a static JSON schema payload in Swift that matches that model closely.
- Send `responseMimeType: "application/json"` and `responseJsonSchema` in the request body.
- Decode the returned JSON into the Swift model and treat decoding as validation.

### Thinking level

Default phase-1 setting:

- `thinkingLevel = low`

Optional future override:

- `minimal`

### Media resolution

Important repo decision:

- Phase 1 should not depend on `media_resolution`.
- Current docs note that `media_resolution` is only available in `v1alpha`.
- To minimize avoidable API mistakes, start with `v1beta` calls that omit `media_resolution` entirely.
- If later needed, add a version-gated `v1alpha` path behind a setting and explicit tests.

## Visual Analysis Schema

Use the generic prompt's schema categories, but implement them as Swift types that fit the repo.

Minimum required categories:

- summary
- short caption
- long caption
- asset role candidates
- visible characters / people
- props
- animals / vehicles when present
- scene setting
- topography
- terrain
- foliage
- architecture
- weather
- season
- time of day
- lighting
- camera and composition
- style / palette / mood
- retrieval tags and search phrases
- quality flags
- confidence / uncertain fields

Project-specific rules:

- Use lower_snake_case tags.
- Do not hallucinate project character names.
- Only map to real app characters or places after a separate normalization step.
- Preserve both positive tags and negative / contradiction tags.
- Keep the raw model JSON for later migrations.

## Tag Normalization Strategy

Phase 1 should not attempt heavy ontology magic.

Normalize tags in three layers:

1. Raw model tags
2. Canonical normalized tag slugs
3. Optional app-entity matches

Examples of app-entity matches:

- character IDs from `AnimationCharacter`
- place IDs from `BackgroundPlate`
- world-node links from `PlaceWorldNode`

Matching inputs may include:

- existing linked place IDs from generation metadata
- current record ownership from asset links
- character slugs or IDs from the owning source record
- known project character descriptions
- known place names, notes, and briefs

Do not let normalization overwrite raw model output.

## Queue And Worker Design

### Worker lifecycle

The worker should start and stop with the open project.

Suggested lifecycle hooks:

- start / resume from `AnimateStore.openOWP(...)`
- stop / suspend from `AnimateStore.suspendBackgroundWork()` and project teardown

### Queue behavior

- One persisted job per asset / schema / model configuration
- Initial concurrency: 1
- Retriable stages with exponential backoff
- 429 and quota errors should reschedule, not hot-loop
- Worker should be safe to restart at any time

### Stage order

1. discover or refresh asset row
2. local inspection
3. visual analysis
4. tag normalization
5. image embedding
6. semantic metadata embedding
7. optional QC / neighbor precompute
8. mark run complete

### Idempotency key

Use:

- `imageAssetID + contentHash + analysisSchemaVersion + visualModelID + embeddingModelID + embeddingDimension`

Do not create duplicate runs or duplicate tag assignments when the same job is queued twice.

## Search And Retrieval Design

### Search service inputs should align with existing repo concepts

Use scene / shot / place / character data already in `AnimateUI`, not a parallel story model.

Preferred service APIs:

- `searchByTags(...)`
- `searchByText(...)`
- `findSimilarImages(...)`
- `selectForShot(sceneID:shotID:moment:maxImages:)`

### Text-query embedding rule

Because `gemini-embedding-2` does not use `task_type`, construct consistent query text manually.

Recommended format:

`task: find reference images | scene: ... | shot: ... | characters: ... | place: ... | time: ... | camera: ... | notes: ...`

### Retrieval layers

1. Hard filters from normalized tags and manual rejection state
2. Semantic metadata vector similarity
3. Visual similarity checks against already selected or approved images

### Manual-production signals that must influence ranking

- place `rating`
- place `isRejected`
- place `canonStatus`
- place `qaFlags`
- node approved image pointers
- character rejected paths
- character curated inspiration paths
- selected scene-shot images
- XMP rejection state

## Reference Selector Strategy

### Input source for selector

Build the selector input from:

- `AnimationScene`
- `AnimationSceneShot`
- `SceneDirectionTemplate`
- `SceneShotPreset`
- scene character IDs and slugs
- `BackgroundPlate`
- `PlacesScriptIndexService` requirements
- current place / world-node continuity state when available

### Output goal

Return a small, role-diverse set of references with reasons.

Recommended roles:

- `character_reference`
- `location_reference`
- `prop_reference`
- `style_reference`
- `continuity_reference`

### Default caps

- keep current app default at 5 references initially
- make it configurable later up to the model limit

### Initial scoring weights

- `0.30` semantic similarity
- `0.25` required character match
- `0.15` place / setting match
- `0.10` time / lighting match
- `0.10` terrain / foliage / topology match
- `0.05` prop match
- `0.05` manual approval / quality boost

### Disqualifiers

- explicit manual rejection
- unusable quality flag
- wrong linked character when a specific character is required
- missing file
- embedding model or dimension mismatch

## Live Integration Hooks

### Principle

Register and enqueue at the persistence seam, not at random UI call sites when a view refresh happens.

### Initial hook list for implementation agents

Patch these or their closest storage helpers:

- `AnimateStore.storeGeneratedInspirationImage(...)`
- `AnimateStore.storeGeneratedPlaceImage(...)`
- `AnimateStore.storeUnattachedGeneratedImage(...)`
- `AnimateStore.importInspirationImages(...)`
- `AnimateStore.importInspirationImages(from:for:)`
- `AnimateStore.setInspirationReferenceImage(from:for:)`
- `AnimateStore.importReferenceImages(...)`
- `AnimateStore.importReferenceImages(from:for:)`
- `AnimateStore.addPlaceReferenceImagesFromPicker(...)`
- `AnimateStore.addGlobalPlaceReferenceImagesFromPicker(...)`
- `ImagineProjectStorage.saveGeneratedImage(...)`
- `ImagineProjectStorage.importImage(...)`
- `AnimateStore.appendCanvasGeneration(...)`

Integration rule:

- persistence happens first
- asset registration happens second
- queue enqueue happens third
- UI returns immediately

If a path is missed, the backfill scanner must still discover it later.

## Backfill Strategy

### Primary entrypoint

Use an app-internal backfill service plus a settings action first.

Why:

- This repo does not currently have a dedicated maintenance CLI for Animate image workflows.
- A button or debug action in settings fits current app patterns better.

### Backfill responsibilities

- discover all current image assets
- register missing asset rows
- find stale or incomplete analyses
- enqueue only what is missing or stale
- support dry run
- support batch size limit
- support resume

### Backfill inputs

- current in-memory model sources
- on-disk scan of scene-shot directories
- on-disk scan of relevant image folders if model references are incomplete

## Existing Metadata Reuse Rules

### Read as context

- generation `.json` sidecars
- XMP review `.xmp` sidecars
- DrawThings `.prompt.txt` files
- `GeneratedBackgroundLibraryRecord.summary`
- `GeneratedBackgroundLibraryRecord.keywords`
- `sourcePrompt`

### Do not treat as primary truth

- filenames
- prompt text alone
- summary / keyword heuristics generated from filenames

### Do not overwrite existing user-authored fields

- place notes
- place visual briefs
- place prompt support text
- character notes / backstory / personality
- shot notes
- scene direction notes

## Execution Phases

The phases below are intentionally small and reviewable. Lower-cost agents should not jump ahead.

### Phase 1: Foundation And Settings

Scope:

- add the separate image-analysis Gemini API key to `ProjectCredentialStore`
- add `AnimateStore` state and accessors for the separate key
- add settings UI for image analysis fields
- add a feature flag and defaults
- add `ProjectPaths.imageIntelligenceSQLite`

Files likely touched:

- `ProjectPaths.swift`
- `ProjectCredentialStore.swift`
- `AnimateStore.swift`
- `GeminiSettingsSheet.swift`

Definition of done:

- image-analysis key is stored separately from generation key
- no existing generation path changed behavior
- UI clearly labels analysis vs generation credentials
- no Vertex configuration is referenced by analysis settings

Tests:

- credential payload round-trip
- masking / clearing behavior
- generation key and analysis key do not alias each other

### Phase 2: Image Intelligence Store And Asset Registry

Scope:

- create the dedicated SQLite store and migrations
- create `image_assets` and `image_asset_links`
- implement register / refresh / lookup operations
- implement local inspection helpers for hash, dimensions, mime type, file size

Definition of done:

- any image path can be registered once and linked to one or more app owners
- content hash updates when file bytes change
- repeated registration is idempotent

Tests:

- schema creation
- asset dedupe by resolved path plus content hash refresh
- multiple links for one asset
- file-changed re-registration marks asset stale

### Phase 3: Discovery And Backfill Inventory

Scope:

- implement discovery from all required repo sources
- implement a dry-run backfill report
- implement queueable backfill batches

Definition of done:

- the scanner can discover all current images from places, characters, scene shots, and canvas
- backfill can report missing vs complete vs stale

Tests:

- discovery over fixture project with at least one image from each source class
- repeated backfill dry runs produce stable counts

### Phase 4: Gemini Analysis Client

Scope:

- create `GeminiImageAnalysisService`
- implement visual analysis request / response decoding
- implement image embedding request
- implement semantic metadata embedding request
- add hard guards against Vertex usage

Definition of done:

- service only hits `generativelanguage.googleapis.com`
- service only uses explicit analysis key
- service can decode valid structured JSON into Swift models

Tests:

- request URL assertions
- header assertions
- analysis key selection order
- decoding / validation tests
- no `task_type` in embedding requests
- no multi-input aggregation bug in stored embeddings

### Phase 5: Queue, Runs, And Worker

Scope:

- create job and run tables
- implement worker loop and stage transitions
- persist partial stage success
- implement backoff and failure terminal states

Definition of done:

- a queued image can progress through all stages end to end with mocked Gemini responses
- stage success is not recomputed unnecessarily
- retries are bounded and durable

Tests:

- retry behavior
- idempotency
- partial stage resume
- failure transitions

### Phase 6: Live Persistence Hooks

Scope:

- call register-and-enqueue helpers from the known persistence seams
- wire scene-shot and canvas paths

Definition of done:

- newly generated or imported images are registered and queued without blocking the UI
- existing save flows still return immediately

Tests:

- place generation enqueue
- character import enqueue
- scene-shot save enqueue
- canvas append enqueue

### Phase 7: Search And Selector Services

Scope:

- implement structured search
- implement text-query search
- implement similar-image search
- implement shot-based selector using current scene / shot / place / character models

Definition of done:

- selector can choose role-diverse images and explain why
- rejection and quality constraints are respected

Tests:

- search filters
- similarity search model / dimension guard
- selector diversity and hard constraints

### Phase 8: Minimal Status Surfaces

Scope:

- expose analysis status in existing UI surfaces without redesigning the app
- add reanalyze and backfill actions
- add safe error display

Recommended first surfaces:

- settings sheet
- all-project-images inspector
- place image detail views where a record already exists

Definition of done:

- user can tell whether an image is pending, complete, failed, or stale
- user can trigger reanalysis and backfill

### Phase 9: Documentation And Review Prep

Scope:

- operator docs
- privacy note
- schema / model versioning note
- clear explanation of what is stored where

Definition of done:

- another agent can understand the subsystem without reverse engineering the code

## Implementation Guardrails For Future Agents

- Keep changes additive.
- Prefer new files under `Services/ImageIntelligence/` instead of modifying unrelated generation services.
- Do not touch `VertexAIClient.swift` for this feature.
- Do not route analysis through `ImageGenBackendStore`.
- Do not make `AllProjectImagesWorkspace` the persistence layer; it is only a discovery reference.
- Do not overwrite `GeneratedBackgroundLibraryRecord.summary`, `keywords`, or `sourcePrompt` with Gemini analysis. Store analysis in new tables.
- Do not overwrite place or character approval state.
- Do not add network calls in tests.
- Do not add build / deploy steps to the implementation workflow until Gary explicitly requests it.

## Verification Strategy

Allowed during implementation:

- targeted unit tests in `Packages/Animate/Tests/AnimateTests`
- targeted unit tests in `Packages/ProjectKit/Tests/ProjectKitTests`
- narrow compile / test loops as needed

Not allowed until Gary says:

- `Scripts/build-app.sh`
- deployment to `!Applications`
- broad ship-style verification for this subsystem

## Acceptance Checklist

The implementation is only acceptable when all of the following are true.

- existing images can be discovered and backfilled
- newly imported images queue analysis automatically
- newly generated images queue analysis automatically
- foreground import and generation do not wait for analysis
- the analysis key is separate from the generation key
- analysis requests never use Vertex AI
- raw validated analysis JSON is stored
- normalized searchable tags are stored
- image embeddings and semantic embeddings are stored with model and dimension metadata
- selector input is built from this repo's real scene / shot / place / character models
- selector returns scored references with reasons
- idempotency and resume behavior are covered by tests
- no API keys, base64 image payloads, or full vectors are logged

## Recommended First Execution Command For Future Agents

When Gary later tells a cheaper model to execute this plan, the first implementation task should be:

1. Phase 1 only.
2. Stop after tests for phase 1 pass.
3. Summarize exactly which files changed and which later phases remain.

That keeps the review surface small and reduces the chance of a broad, hard-to-review initial landing.
