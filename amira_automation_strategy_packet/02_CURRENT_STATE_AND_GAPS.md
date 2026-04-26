# 02 — Current State and Gaps

## What already exists and should be trusted

| Area | Current state | Trust level |
|---|---|---|
| Local app shell | `Sources/Opera` opens local project folders and routes modes into Animate. | High |
| Write/script loading | `ScriptStore.swift` loads `.ows`, project folders, characters, scratchpad, history. | High |
| Scene/shot store | `Scenes/scenes.json` is current app-facing scene store. | High |
| Places | `Places/places.json` has 27 deduped places with approved images and prompt fields. | High |
| World context | `Places/places-world-context.json` is canonical; early-2000s world. | High |
| Characters | 6 character rig folders with `rig.json`, references, look-dev fields. | High |
| Animated look | `Settings/animated-look-prompt.json` is global style source. | High |
| Image generation | `GeminiImageService` and `ImagineGenerationService` generate and save sidecars. | Medium-high |
| Vidu client | `ViduAPIService` exists for task creation, polling, download. | Medium |
| Image Intelligence | Discovery, analysis, tags, embeddings, image links, selector exist/recently exist. | Medium |
| Score API | Score playback/export API exists after Score page loads. | Medium |

## Live project counts to validate

Expected live project shape:

```text
Scenes: 52
Shots: 367
Places: 27
Songs: 52 .ows files
Character rig folders with rig.json: 6
Scenes with backgroundID: 51 / 52
Scene backgroundID values mapping to place ID: 51 / 52
Shots with populated shotFrameGeneration: 0
Shots with populated shotBackgroundPlate: 0
```

## Canonical sources

| Domain | Canonical source |
|---|---|
| Song/libretto text | `Songs/*.ows` |
| Scene/shot plan | `Scenes/scenes.json` |
| Places/world model | `Places/places.json` |
| World context | `Places/places-world-context.json` |
| Characters | `Characters/*/rig.json` |
| Animated look | `Settings/animated-look-prompt.json` |
| Reference registry | `Animate/reference-registry.json` and `.md` |

## What is partial

| Area | Partial implementation | Missing completion |
|---|---|---|
| Shot seeding | Existing shots are seeded from script directions and lyric timing. | Rich dictated-shot import and re-run behavior. |
| Shot frame planning | Recent branch describes `ShotFrameGenerationPlan`. | Stable contract, API, queue, UI status. |
| Reference selection | `ImageSearchService.selectForShot` exists/recently exists. | Persisted editable `ReferenceContract`. |
| Open-matte planning | Recent branch direction exists. | Formal sidecar and crop preview. |
| Vidu handoff | `ViduAPIService` exists. | Upload/public URL strategy and wired queue. |
| QA | Image analysis infrastructure exists. | Comparison against shot specs/reference contracts. |
| Manual overrides | UI has prompt editing, refs, thumbnails, dry-runs. | Unified override ledger across stages. |
| APIs | Basic Animate API exists. | Complete loopback command surface. |

## What is missing

1. Formal dictation-to-shot-spec importer.
2. Persisted, editable `ReferenceContract`.
3. Resumable shot-frame generation queue.
4. Complete local-frame-to-video-provider handoff.
5. QA/correction loop for frames and videos.
6. Unified manual override ledger.
7. Cost/dry-run controls across the whole pipeline.
8. Branch cleanup: confirm whether to build from `main` or recent feature branch.

## Weak-area analysis

### Schema gaps

Missing or incomplete:

- `TranscriptImport`
- `TranscriptShotSpec`
- `EffectiveShotSpec`
- `ReferenceContract`
- `ShotFrameGenerationPlan`
- `GeneratedFrameRecord`
- `VideoTaskRecord`
- `QAResult`

### API gaps

The Animate API should let agents run dry-runs, inspect outputs, queue jobs, and resume safely without driving the UI.

Needed first:

```http
GET  /automation/project/summary
GET  /automation/shots/{shotID}/effective-shot-spec
POST /automation/references/resolve
GET  /automation/references/{sceneID}/{shotID}
POST /automation/frame-plans/dry-run
POST /automation/frames/generate
POST /automation/videos/queue
POST /automation/videos/tasks/{taskID}/poll
POST /automation/qa/frame
POST /automation/qa/video
```

### UI gaps

A single Shot Production Inspector should show:

```text
Shot spec
References
Frame plan
Generated frame variants
Approvals
Video task
QA results
Retry/manual-review state
```

### Metadata gaps

Save these now:

| Artifact | Must save |
|---|---|
| Transcript import | raw text, cleaned text, segment IDs, source timestamps if available |
| Shot spec | LLM output, validation status, manual edits, original excerpt |
| Reference contract | selected refs, rejected refs, scores, reasons, roles, resolver version |
| Frame plan | prompt text, provider, refs, generate/edit mode, source image, crop plan |
| Generated image | prompt, response, seed/settings if available, refs, cost estimate, QA result |
| Video task | provider, model, URLs, local paths, status, duration, prompt, output path |
| QA | checks, pass/fail, correction suggestion, retry attempt |

### Risk areas

| Risk | Mitigation |
|---|---|
| Wrong place drift | Require place ID + approved place image + geography anchors. |
| Wrong character drift | Require exact slug + identity/costume references. |
| Wrong world period | Inject canonical early-2000s world context. |
| Wrong bridge/map geography | Require map refs for outdoor geography and bridge refs for bridge shots. |
| Style drift | Always include animated look prompt/style constraints. |
| Silent paid mistakes | Dry-run first; cost caps; explicit execute mode. |
| Lost manual decisions | Persist pins, rejections, approvals, overrides. |
| Stale branch assumptions | Confirm and normalize implementation branch before coding. |
