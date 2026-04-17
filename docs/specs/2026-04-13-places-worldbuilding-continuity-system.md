# Places Worldbuilding Continuity System

**Date:** 2026-04-13  
**Status:** Implementation-ready spec  
**Scope:** Extend the existing Places workflow into a map-driven, Street-View-like worldbuilding and continuity system for exterior world references, generated background plates, and canon review.

---

## 1. Goal

Build the next layer of the existing Places workflow so the master map becomes the source of truth for:

- route layout
- camera nodes and travel paths
- camera pose and focal metadata
- generated exterior images and approved canon images
- continuity review decisions
- route-batch generation planning

This is **not** a generic asset browser and **not** a full 3D reconstruction system. For v1, the correct foundation for this repo is a **map-anchored pose graph** inside Places:

- the master map is the anchor
- roads/pathways become routes
- routes are sampled into world nodes
- each generated or imported exterior image is attached to a node/view
- continuity decisions happen against adjacent nodes and approved canon

That gives Amira Writer a practical “primitive Street View” for the fictional world while staying compatible with the current Places UI, Places JSON manifests, Gemini generation flow, and generated background library.

---

## 2. Current Repo Fit

The live implementation should extend the **existing Places workflow**, not create a parallel subsystem.

### 2.1 Canonical UI entrypoints

Use these files as the primary UI surfaces:

1. `Packages/Animate/Sources/AnimateUI/PlacesWorkspace.swift`
2. `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`
3. `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`
4. `Packages/Animate/Sources/AnimateUI/Views/GeminiGenerationPreflightSheet.swift`

### 2.2 Canonical persistence split

Use the following split for v1:

- `Animate/places.json`
  - continue to hold the per-place shell via `[BackgroundPlate]`
- `Animate/places-workflow.json`
  - hold world graph, routes, nodes, continuity reviews, and canon queue state via `PlacesWorkflowLibrary`
- image sidecar metadata (`StoredImageGenerationMetadata`)
  - hold per-image pose/focal/node/batch metadata adjacent to each image file

### 2.3 Important live constraints already discovered

1. **Places batch submission already exists** via the Gemini batch path.
2. **Place batch outputs currently land under** `Animate/backgrounds/place-batches/...`.
3. **Those place-batch outputs are not auto-ingested yet** by the generated background library because the scanner currently whitelists:
   - `/backgrounds/places/`
   - `/backgrounds/chosen-references/`
   - `/backgrounds/pipeline/tests/`
   - `/backgrounds/pipeline/batches/`
   - but **not** `/backgrounds/place-batches/`
4. The current Places preflight can already support **5-image 2K test runs** by launching the existing 8-draft flow and selecting only 5 drafts before submission.
5. For QA/regeneration, the existing library edit batch path is more production-ready than the current place-batch ingestion path.

These constraints should shape the build order below.

---

## 3. System Overview

## 3.1 Core concept

The continuity system adds a **world graph** on top of Places.

### World graph hierarchy

- **Master Map**
  - one project-level image/map reference already used by Places
- **Routes**
  - named traversable paths traced over the map
- **Nodes**
  - sampled camera positions along a route
- **Views / Captures**
  - generated or imported images attached to a node and camera pose
- **Canon decisions**
  - which capture is currently approved for that node or continuity context
- **Continuity reviews**
  - mismatch records comparing neighboring views and canon expectations

### Street-View-like behavior in repo terms

For v1, the “Street View” effect comes from:

- route polylines on the master map
- sequential node placement along those routes
- per-node forward/left/right/reverse view generation
- neighboring node comparison
- a filmstrip/review queue built from node order

No full volumetric 3D model is required for v1.

---

## 3.2 Continuity QA model

Continuity should use **three layers**, in this order:

### Layer A — Image similarity / overlap

Goal: flag obvious visual drift between adjacent views.

Use this layer to detect:

- large composition drift between neighboring nodes
- duplicate or near-duplicate outputs when diversity was expected
- abrupt environmental changes that do not fit route adjacency

Initial signals can be stored as lightweight numeric metadata per generated record:

- perceptual hash distance
- embedding similarity score
- optional future geometry/feature-match score

### Layer B — Metadata alignment

Goal: verify the image is attached to the right spatial slot.

Use metadata alignment to check:

- route ID matches selected generation batch
- node ID exists and belongs to selected place/route
- sequence index is in order
- heading/yaw matches the requested direction band
- focal length/FOV matches the planned preset
- neighbor links exist for left/right/previous/next review

This layer is the backbone of the map-driven system. Even if image-recognition signals are imperfect, bad metadata alignment should still force review.

### Layer C — Human canon review

Goal: make final world-truth decisions explicit and auditable.

Human review decides:

- keep as canon
- keep as candidate
- reject
- supersede prior canon
- mark needs follow-up generation

The system should optimize for **surfacing decision points**, not auto-deciding canon.

---

## 4. Concrete Implementation Spec

## 4.1 Data model changes

### Primary file

`Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`

### Add new worldbuilding structs/enums

Add the following new types here:

- `WorldMapPoint`
- `WorldCameraPose`
- `PlaceWorldGraph`
- `PlaceWorldRoute`
- `PlaceWorldNode`
- `PlaceWorldEdge`
- `PlaceWorldViewCapture`
- `PlaceContinuityReview`
- `PlaceQAFlag`
- `WorldCanonStatus`

### Recommended responsibilities

#### `WorldMapPoint`
Holds map-space position.

Recommended fields:
- `x`
- `y`
- optional `z`
- optional `mapCoordinateSpace`

#### `WorldCameraPose`
Holds the authored camera pose for a view.

Recommended fields:
- `yaw`
- `pitch`
- `roll`
- `focalLength35mm`
- optional `hfov`
- optional `vfov`
- optional `distanceBand`

#### `PlaceWorldRoute`
Represents a road/path traced on the master map.

Recommended fields:
- `id`
- `placeID` or route scope
- `name`
- `nodeIDs`
- `polyline`
- `isPrimary`

#### `PlaceWorldNode`
Represents one camera anchor point on a route.

Recommended fields:
- `id`
- `placeID`
- `routeID`
- `sequenceIndex`
- `mapPoint`
- `defaultPose`
- `neighborNodeIDs`
- `expectedLandmarkTags`
- `notes`

#### `PlaceWorldViewCapture`
Represents one image attached to a node/view.

Recommended fields:
- `id`
- `placeID`
- `worldNodeID`
- `generatedBackgroundRecordID` or linked image path
- `cameraPose`
- `workflow`
- `promptSummary`
- `referenceImagePaths`
- `canonStatus`
- `qaFlags`
- `createdAt`

#### `PlaceContinuityReview`
Represents one review item in the continuity queue.

Recommended fields:
- `id`
- `placeID`
- `primaryRecordID`
- `neighborRecordIDs`
- `worldNodeID`
- `routeID`
- `reviewReason`
- `qaFlagIDs` or copied flag payloads
- `decision`
- `reviewedAt`
- `reviewNotes`

#### `PlaceQAFlag`
Represents an automated or manual mismatch.

Recommended fields:
- `id`
- `recordID`
- `kind`
- `severity`
- `summary`
- `details`
- `metricValue`
- `expectedValue`
- `createdAt`

#### `WorldCanonStatus`
Recommended cases:
- `candidate`
- `canon`
- `needsReview`
- `rejected`
- `superseded`

### Extend existing models

#### `PlaceAngleImage`
Add node-aware fields for manual/imported angle references:

- `worldNodeID: UUID?`
- `routeID: UUID?`
- `sequenceIndex: Int?`
- `cameraPose: WorldCameraPose?`
- `mapPoint: WorldMapPoint?`
- `linkedGeneratedRecordID: UUID?`
- `canonStatus: WorldCanonStatus`

#### `GeneratedBackgroundLibraryRecord`
Add continuity QA and canon linkage:

- `linkedPlaceID: UUID?`
- `worldNodeID: UUID?`
- `cameraPose: WorldCameraPose?`
- `qaFlags: [PlaceQAFlag]`
- `continuityReviewIDs: [UUID]`
- `canonStatus: WorldCanonStatus`
- `neighborRecordIDs: [UUID]`

#### `PlacesWorkflowLibrary`
Add top-level worldbuilding state:

- `worldGraph: PlaceWorldGraph`
- `continuityReviews: [PlaceContinuityReview]`
- `qaDecisionQueue: [UUID]`

### Keep `BackgroundPlate` mostly place-level

Do **not** overload `BackgroundPlate.approvedImagePath` into node-level canon.

Optional additions only:
- `defaultWorldNodeIDs: [UUID]`
- `primaryWorldAnchor: WorldMapPoint?`

Node-level canon should live in the new world graph and linked generated records.

---

## 4.2 Store, save/load, and metadata wiring

### Primary file

`Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

### Existing state anchors

These are the core live state anchors for the system:

- `placesWorkflowLibrary`
- `selectedGeneratedBackgroundRecordID`
- `selectedPlace`
- `indexedPlaces`

### Extend sidecar metadata

Extend `StoredImageGenerationMetadata` to include:

- `linkedPlaceID`
- `worldNodeID`
- `routeID`
- `sequenceIndex`
- `cameraPose`
- `mapPoint`
- `canonStatus`
- batch submission identifiers / batch path if present

### Required metadata hooks

Update these paths so pose/focal/node info round-trips with image sidecars:

- `writeGenerationMetadata(...)`
- `generationMetadata(for:)`
- `derivedGeneratedBackgroundMetadata(...)`

### Required save/load and normalization touchpoints

The world graph must be persisted through the existing Places workflow persistence path:

- `save(writePlaces:)`
- `loadPlaces(...)`
- `loadPlacesWorkflowLibrary(...)`
- `hydratedPlacesWorkflowLibrary(...)`
- `persistedPlacesWorkflowLibrary(...)`
- `hydratedBackgroundPlate(...)`
- `persistedBackgroundPlate(...)`

### Required mutation points

These mutation APIs must gain world-node awareness or companion APIs:

- `addImageToPlace(from:placeID:workflow:)`
- `attachExistingImageToPlace(path:placeID:workflow:)`
- `setApprovedPlaceImage(_:placeID:workflow:)`
- `addAngleImageToPlace(...)`
- `addPlaceReferenceImage(...)`
- `setMasterPlaceMap(from:)`
- `updatePlaceWorkflowConfig(...)`
- `appendPlaceImagePath(...)`

### Required continuity helpers

Update or add helpers for node-first continuity resolution:

- `preferredPlaceContinuityImagePath(...)`
- `requiredCameraShots(for:)`

Add new store APIs:

- `worldViews(for placeID: UUID) -> [PlaceWorldViewCapture]`
- `attachRecord(_:toWorldNodeID:)`
- `updateWorldViewPose(...)`
- `setCanonWorldView(...)`
- `recordContinuityReview(...)`
- `flagWorldViewQA(...)`
- `continuityReviewQueue() -> [PlaceContinuityReview]`

### Required generated-library preservation work

These code paths must preserve QA and canon state during merge/dedupe:

- `syncGeneratedBackgroundLibrary()`
- `mergeGeneratedBackgroundRecords(...)`
- `normalizeGeneratedBackgroundRecord(...)`

### Script-refresh safety

When place manifests are refreshed from script data, preserve/prune node bindings by place ID:

- `refreshPlacesFromScript(...)`
- `applyScriptPlaceRequirements(...)`

---

## 4.3 UI implementation spec

## 4.3.1 Sidebar and center-pane mode changes

### Primary file

`Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`

### Add new center modes

Extend `PlacesViewMode` with map-driven continuity modes:

- `.map`
- `.routes`
- `.reviewQueue`

### Sidebar changes

Use `PlacesSidebarView.body` to add these top-level rows:

- `Show All Images`
- `Map`
- `Routes`
- `Review Queue`

Use `PlacesSidebarView.placeRow(_:)` to surface place-level worldbuilding status:

- route count
- node count
- flagged review count
- canon count

### Main content routing

Use `PlacesPageView.mainContent` to route new modes.

Keep `overviewSection` as the high-level summary pane, but add a direct path into the full map.

Use `masterMapOverviewCard` as the compact preview entrypoint, not the full implementation surface.

---

## 4.3.2 Map mode

### Purpose

This is the main “world graph browser” view.

### Wireframe

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Places / Map                                           [Route ▾] [Place ▾] │
├──────────────────────────────────────────────────────────────────────────────┤
│ Toolbar: [Select] [Trace Route] [Add Node] [Auto Sample] [Show Cones ✓]    │
│         [Only Canon ✓] [Flagged Only] [2K Test Batch] [Open Review Queue]  │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   MASTER MAP CANVAS                                                          │
│   - master map image                                                         │
│   - route polylines                                                          │
│   - node dots with sequence labels                                           │
│   - selected node cone showing yaw/FOV                                       │
│   - canon nodes marked green                                                 │
│   - flagged nodes marked orange/red                                          │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│ Selected Route Filmstrip                                                     │
│ [001] [002] [003] [004] [005] ...                                            │
│ each card: thumb / heading / focal / canon badge / flag count               │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Responsibilities

Map mode should support:

- showing the master map
- drawing/editing routes
- showing sampled nodes
- visualizing selected node heading and FOV cone
- selecting a node to inspect/edit
- launching route batch generation
- filtering to canon or flagged nodes only

### Recommended live hooks

- `PlacesPageView.mainContent`
- `PlacesPageView.masterMapOverviewCard`
- `PlacesPageView.placeHeader(_:)`

---

## 4.3.3 Node editing and camera metadata

### Primary files

- `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

### Existing reusable surfaces

In `PlacesPageView.swift`:

- `angleImagesSection(_:)`
- `AngleImageCard`
- `AngleImageCard.body`
- `AngleImageCard.angleImageEditor`

In `InspectorView.swift`:

- `InspectorView.body`
- `PlaceAssetsInspectorSection.body`
- `PlaceGeneratedImageDetailsInspectorSection.metadataSection(for:)`

### Implementation direction

Reuse the angle-image editing surface as the first node metadata editor rather than inventing a brand-new editor stack.

### Node inspector wireframe

```text
┌─────────────────────────────────────── Inspector ───────────────────────────┐
│ Tabs: [Properties] [Assets] [Node] [Gemini] [Review]                        │
├──────────────────────────────────────────────────────────────────────────────┤
│ Node                                                                         │
│ Node ID: route-market-014                                                    │
│ Route: Market Road                                                           │
│ Sequence: 14                                                                 │
│ Map Position: x=0.482 y=0.317                                                │
│                                                                              │
│ Camera                                                                       │
│ Yaw: 086°   Pitch: -2°   Roll: 0°                                            │
│ Focal: 35mm   HFOV: 54°                                                      │
│ View preset: Forward                                                         │
│                                                                              │
│ Linked Images                                                                │
│ Approved Canon: [thumbnail]                                                  │
│ Candidates: 4                                                                │
│ Neighbors: prev / next / left / right                                        │
│                                                                              │
│ QA                                                                           │
│ Similarity: 0.88                                                             │
│ Metadata: aligned                                                            │
│ Review state: needs review                                                   │
│                                                                              │
│ [Set Canon] [Reject] [Open Compare] [Queue Regeneration]                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Required editable fields

The node editor must handle:

- node ID / route ID
- sequence index
- yaw / pitch / roll
- focal length / FOV
- linked generated record
- canon status
- review notes

---

## 4.3.4 Continuity review queue

### Primary files

- `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

### Existing reusable surfaces

In `PlacesPageView.swift`:

- `allImagesLibrarySection`
- `PlaceAllImagesGallerySection`
- `PlaceAllImagesThumbnail`
- `workflowOutputSection(_:)`

In `InspectorView.swift`:

- `PlaceGeneratedImageDetailsInspectorSection.previewCard(for:)`
- `ratingSection(for:)`
- `metadataSection(for:)`
- `versionHistorySection(for:)`
- `editHistorySection(for:)`

### Review queue wireframe

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Review Queue                                      Filters: [Flag ▾] [Place ▾]│
├──────────────────────────────────────────────────────────────────────────────┤
│ Left column: queue list                                                     │
│ - Market Road / Node 014 / Missing-right-building                          │
│ - Bridge Walk / Node 003 / Focal mismatch                                  │
│ - Upper Terraces / Node 021 / Low similarity to neighbor                   │
├──────────────────────────────────────────────────────────────────────────────┤
│ Main compare panel                                                         │
│ [Prev Node] [Candidate] [Next Node]                                        │
│ Map mini-view with selected node cone                                      │
│ QA flags:                                                                  │
│ - similarity drift                                                         │
│ - yaw mismatch                                                             │
│ - unresolved canon                                                         │
│                                                                            │
│ Actions: [Keep Candidate] [Set Canon] [Reject] [Queue Fix Batch]           │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Badge requirements

Update thumbnail-level badges to show:

- mismatch flagged
- pending decision
- canon
- route / node / sequence

### Decision model

A review item should always produce a durable state change:

- update `WorldCanonStatus`
- attach or clear QA flags
- append review history
- optionally queue regeneration

---

## 4.3.5 Batch generation planning

### Primary files

- `Packages/Animate/Sources/AnimateUI/Views/PlacesPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`
- `Packages/Animate/Sources/AnimateUI/Views/GeminiGenerationPreflightSheet.swift`

### Existing reusable surfaces

In `PlacesPageView.swift`:

- `generationStudioSection(_:)`
- `prepareGenerationPlan(for:count:)`
- `generationSpecs(for:)`
- `generationReferenceDrafts(for:workflow:)`
- `generationContextNote(for:workflow:)`

In `InspectorView.swift`:

- `PlaceGeminiInspectorSection.body`
- `PlaceGeminiBatchInspectorSection.body`
- `queueRow(_:)`
- `jobRow(_:)`

In `GeminiGenerationPreflightSheet.swift`:

- `GeminiGenerationPreflightSheet.body`
- `summaryCard`
- `sharedConfigurationCard`
- `requestCard(_:)`
- `footer`

### Required batch concepts

The batch UI should evolve from “generate N drafts for this place” to “generate views for these route nodes.”

Each request should include:

- route ID
- node ID
- sequence index
- requested heading/view preset
- focal preset
- continuity anchors
- output path target
- workflow (`photoreal` / `animated`)

### Preflight wireframe

```text
┌──────────────────────────── Gemini Route Batch Preflight ───────────────────┐
│ Summary                                                                      │
│ Place: Market District                                                       │
│ Route: Market Road                                                           │
│ Nodes: 14-18 (5 requests)                                                    │
│ Output Size: 2K                                                              │
│ Workflow: Photoreal                                                          │
│ Continuity Mode: Use previous canon + route neighbors                        │
│                                                                              │
│ Shared Configuration                                                         │
│ [x] Use approved canon as first reference                                    │
│ [x] Include previous node                                                    │
│ [x] Include next node if available                                           │
│ [x] Write node/focal metadata to sidecars                                    │
│                                                                              │
│ Requests                                                                     │
│ 014  Forward  35mm  refs: canon+013                                          │
│ 015  Forward  35mm  refs: 014                                                │
│ 016  Forward  35mm  refs: 015                                                │
│ 017  Forward  35mm  refs: 016                                                │
│ 018  Forward  35mm  refs: 017                                                │
│                                                                              │
│ [Generate Now] [Submit Batch] [Cancel]                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5-image 2K test requirement

The system must explicitly support:

- **5-image, 2K route test runs** as a named/testing path
- future larger route batches

Implementation note:
- v1 can ship with a dedicated preset such as `5 Route Drafts (2K Test)`
- until then, the current preflight selection path can already execute 5-of-8 at 2K

---

## 4.4 Batch ingestion and job tracking

### Primary files

- `Packages/Animate/Sources/AnimateUI/Services/GeminiImageService.swift`
- `Scripts/gemini_inspiration_batch.py`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

### Current reality

Batch jobs already write:

- `batch_plan.json`
- `batch_requests.jsonl`
- `prompt_manifest.json`
- `batch_submission.json`
- `watchdog.log`
- `batch_results.jsonl`
- `results/<key>.png|jpg`
- `results/<key>.json`

### Required new behavior

For worldbuilding continuity work, `batch_plan.json` and sidecars must include route/node metadata so the results can be reattached automatically.

### Required ingestion change

Before relying on place batches for the continuity workflow, update generated-image ingestion so `syncGeneratedBackgroundLibrary()` includes:

- `/backgrounds/place-batches/`

Without this, route batches can complete on disk but will not surface in the Places review workflow.

### Operational note

If ingestion is not fixed yet, use the existing edit batch flow for QA-only follow-up runs.

---

## 5. UI / Screen Flow

## 5.1 Entry flow

1. Open `PlacesWorkspace`
2. Choose a place
3. Open `Map` mode
4. Confirm the master map and route overlay
5. Select a route or auto-create one
6. Sample nodes or add nodes manually
7. Select a node
8. Use inspector to set heading/focal defaults
9. Launch a 5-image 2K test route batch
10. Review resulting candidates in `Review Queue`
11. Set canon / reject / queue follow-up batch

---

## 5.2 First-time setup flow per place

```text
Place selected
  → attach master map if missing
  → draw route polyline
  → auto-sample nodes at default spacing
  → select node 001
  → assign default forward view + focal preset
  → generate first 5-node continuity run
  → approve first canon chain
```

This should be the shortest route to usable world continuity.

---

## 5.3 Ongoing review flow

```text
new batch completes
  → results ingest into generated library
  → records attach to nodes via sidecar metadata
  → automatic QA creates flags/reviews
  → Review Queue shows flagged items first
  → human sets canon or reject
  → approved canon becomes next continuity anchor
```

This is the core feedback loop for maintaining world truth over time.

---

## 6. Phased Technical Build Plan

## Phase 0 — Documentation, schema, and path decisions

### Deliverables

- this spec committed under `docs/specs/`
- final names chosen for world graph structs and enum cases
- decision to store graph state in `Animate/places-workflow.json`
- decision to store pose/focal metadata in image sidecars

### Exit criteria

- file/symbol map agreed
- no ambiguity about persistence split

---

## Phase 1 — Persistence foundation

### Work

1. Add world graph structs/enums to `AnimateModels.swift`
2. Extend `PlaceAngleImage`, `GeneratedBackgroundLibraryRecord`, and `PlacesWorkflowLibrary`
3. Extend `StoredImageGenerationMetadata`
4. Wire save/load/hydration paths in `AnimateStore`
5. Ensure merge/dedupe preserves canon/QA metadata

### Tests

Add persistence tests in:

`Packages/Animate/Tests/AnimateTests/PlacesPersistenceTests.swift`

Required tests:

- `PlacesWorkflowLibrary` round-trip with `worldGraph`
- `PlaceAngleImage` pose/focal round-trip
- `GeneratedBackgroundLibraryRecord` QA/canon round-trip
- normalization of any new review-linked asset paths

### Exit criteria

- world graph persists cleanly
- image sidecars persist cleanly
- no metadata loss through save/reload

---

## Phase 2 — Map and node authoring UI

### Work

1. Add new `PlacesViewMode` cases
2. Add sidebar rows for `Map`, `Routes`, `Review Queue`
3. Add map canvas mode in `PlacesPageView`
4. Add route/node rendering over the master map
5. Add selected-node cone and route filmstrip
6. Add node editing in inspector / angle-image editor

### Exit criteria

- user can create/edit routes and nodes from Places
- node pose/focal metadata is editable and persistent
- canon/flag state is visible at a glance on the map

---

## Phase 3 — Batch planning and ingestion

### Work

1. Extend generation planning from place drafts to node batches
2. Add node metadata to request generation specs
3. Add `5 Route Drafts (2K Test)` preset
4. Update preflight summary to show route span and node-level requests
5. Ingest `/backgrounds/place-batches/` into generated background library
6. Reattach results to nodes using sidecar metadata

### Exit criteria

- a 5-node 2K route batch can be submitted from Places
- completed images show up in the library and node review flow
- results are not orphaned on disk

---

## Phase 4 — Continuity QA and review queue

### Work

1. Add `PlaceQAFlag` generation hooks
2. Add continuity review creation and queue ordering
3. Add compare view with prev/candidate/next context
4. Extend inspector rating/review sections to canon decisions
5. Add queue regeneration actions

### Initial QA heuristics for v1

#### Similarity

- perceptual hash distance threshold
- embedding similarity threshold
- duplicate clustering within the same node batch

#### Metadata alignment

- node exists
- route/node mapping valid
- focal preset valid
- heading deviation within tolerance
- previous/next neighbors resolved

#### Human review

- unresolved canon on a node with multiple candidates
- two adjacent nodes disagree beyond threshold
- rejected prior canon but no replacement selected

### Exit criteria

- new batches auto-produce review items when needed
- reviewer can settle canon without leaving Places

---

## Phase 5 — Controlled testing and rollout

### Work

Run the first controlled test passes only after Phases 1-4 are in place.

### Test batches

Run up to:

- **3 test batches**
- **5 images each**
- **2K output size**

Recommended order:

1. one clean forward route segment
2. one route segment with a turn / more varied composition
3. one QA follow-up or regeneration batch for flagged nodes

### Capture during testing

For every test batch, record:

- place
- route
- node range
- workflow
- image size
- request count
- generated result count
- number of auto flags
- number of human canon decisions
- failures / ingestion issues / metadata mismatches

### Exit criteria

- batches can be submitted from Places
- results ingest automatically
- at least one route segment can be reviewed to a stable canon chain
- flagged mismatches are reviewable and actionable

---

## 7. Build/Test Checklist

## 7.1 Unit and persistence checklist

- [ ] `PlacesWorkflowLibrary` world graph survives save/reload
- [ ] `GeneratedBackgroundLibraryRecord` retains canon status through merge/dedupe
- [ ] sidecar metadata round-trips route/node/camera pose fields
- [ ] script refresh does not orphan valid world node bindings

## 7.2 UI checklist

- [ ] sidebar shows `Map`, `Routes`, `Review Queue`
- [ ] map mode renders master map, routes, nodes, and cones
- [ ] selecting a node updates inspector metadata
- [ ] route filmstrip shows canon and flag counts
- [ ] review queue supports compare + decision workflow
- [ ] preflight shows route/node-specific request plan

## 7.3 Batch/integration checklist

- [ ] `backgrounds/place-batches/` is ingestible by generated background library sync
- [ ] completed place batch results become node-linked records
- [ ] 5-image 2K test run works end-to-end
- [ ] QA flags appear after ingestion
- [ ] canon decisions persist after app restart

---

## 8. Non-Goals for v1

These items should not block the first implementation:

- full photogrammetry pipeline
- automatic 3D reconstruction of the world
- full GIS editing toolset
- autonomous canon decisions without human approval
- perfect semantic scene understanding before shipping the first version

The first version should be practical, incremental, and tightly integrated into Places.

---

## 9. Key Decisions

1. **Use a pose graph, not full 3D, for v1.**
2. **Build on Places, not beside it.**
3. **Persist graph/review state in `places-workflow.json`.**
4. **Persist per-image pose/focal/node metadata in existing sidecars.**
5. **Use layered QA: similarity, metadata alignment, then human canon.**
6. **Treat 5-image 2K route tests as a first-class development/testing path.**
7. **Fix place-batch ingestion before relying on route-batch review as the main loop.**

---

## 10. Acceptance Criteria

This feature slice is ready when all of the following are true:

- a place can show a master map with route and node overlays
- a node can hold explicit camera pose/focal metadata
- generated images can be attached to nodes and persist their node metadata
- the review queue can show continuity mismatches and canon actions
- the Places batch preflight can submit a route-based 5-image 2K test run
- completed batch results surface back into Places instead of staying orphaned on disk
- approved canon images can be used as continuity anchors for future batches

