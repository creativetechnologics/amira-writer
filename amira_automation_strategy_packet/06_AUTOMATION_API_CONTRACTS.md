# 06 — Automation API Contracts

## API principles

1. All APIs operate on local project paths.
2. Dry-run endpoints come before paid endpoints.
3. Mutating endpoints write sidecars.
4. Every endpoint returns a report with blockers.
5. Paid generation endpoints require explicit `mode: "execute"`.
6. Queues are resumable.
7. No endpoint silently overwrites user-approved assets.

Base port:

```text
Animate API: localhost:19849
```

## Health and project

```http
GET /health
GET /automation/project/summary
```

Expected `project/summary` fields:

```json
{
  "projectPath": "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera",
  "sceneCount": 52,
  "shotCount": 367,
  "placeCount": 27,
  "characterRigCount": 6,
  "canonicalWorldContextPath": "Places/places-world-context.json",
  "warnings": []
}
```

## Effective shot specs

```http
GET /automation/scenes/{sceneID}/effective-shot-specs
GET /automation/shots/{shotID}/effective-shot-spec
```

Response:

```json
{
  "status": "ok",
  "effectiveShotSpec": {},
  "validation": {
    "status": "valid | blocked | needs_review",
    "errors": [],
    "warnings": []
  }
}
```

## Transcript import

```http
POST /automation/transcripts/import/dry-run
POST /automation/transcripts/{runID}/apply
```

Dry-run request:

```json
{
  "projectPath": "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera",
  "text": "Long dictated transcript...",
  "targetSceneKey": null,
  "llmProvider": "manual_or_external",
  "mode": "dry_run"
}
```

## Reference contracts

```http
POST /automation/references/resolve
GET /automation/references/{sceneID}/{shotID}
POST /automation/references/{sceneID}/{shotID}/pin
POST /automation/references/{sceneID}/{shotID}/reject
POST /automation/references/{sceneID}/{shotID}/rerun
```

Resolve request:

```json
{
  "sceneID": "...",
  "shotID": "...",
  "maxImages": 8,
  "mode": "dry_run | save",
  "includeEmbeddings": true,
  "respectManualOverrides": true
}
```

Pin request:

```json
{
  "path": "/absolute/path.png",
  "role": "manual_pinned",
  "reason": "User chose this as the correct angle."
}
```

Reject request:

```json
{
  "path": "/absolute/path.png",
  "reason": "Wrong location or wrong character."
}
```

## Frame plans

```http
POST /automation/frame-plans/dry-run
GET /automation/frame-plans/{sceneID}/{shotID}
POST /automation/frame-plans/{sceneID}/{shotID}/approve
```

Dry-run request:

```json
{
  "sceneID": "...",
  "shotIDs": ["optional shot subset"],
  "includeReferences": true,
  "includeCostEstimate": true,
  "mode": "dry_run"
}
```

## Frame generation

```http
POST /automation/frames/generate
GET /automation/frames/jobs/{jobID}
POST /automation/frames/jobs/{jobID}/cancel
POST /automation/frames/{sceneID}/{shotID}/approve-variant
```

Generate request:

```json
{
  "sceneID": "...",
  "shotID": "...",
  "moments": ["beginning", "end"],
  "provider": "gemini_vertex",
  "variantCount": 2,
  "mode": "execute",
  "costCap": {
    "maxImageJobs": 2
  }
}
```

## Video tasks

```http
POST /automation/videos/queue
GET /automation/videos/tasks/{taskID}
POST /automation/videos/tasks/{taskID}/poll
POST /automation/videos/tasks/{taskID}/download
POST /automation/videos/tasks/{taskID}/retry
```

Queue request:

```json
{
  "sceneID": "...",
  "shotID": "...",
  "provider": "vidu",
  "durationSeconds": 4,
  "resolution": "1080p",
  "movementAmplitude": "auto",
  "mode": "execute"
}
```

## QA

```http
POST /automation/qa/frame
POST /automation/qa/video
GET /automation/qa/{sceneID}/{shotID}
POST /automation/qa/{sceneID}/{shotID}/accept
POST /automation/qa/{sceneID}/{shotID}/mark-needs-review
```

Frame QA request:

```json
{
  "sceneID": "...",
  "shotID": "...",
  "framePath": "/absolute/path.png",
  "moment": "beginning",
  "mode": "execute"
}
```

Video QA request:

```json
{
  "sceneID": "...",
  "shotID": "...",
  "videoPath": "/absolute/path.mp4",
  "mode": "execute"
}
```

## Error states

Use explicit states instead of silent failures:

```text
blocked_missing_place
blocked_missing_character
blocked_missing_reference_role
blocked_missing_edit_source
blocked_unapproved_start_frame
blocked_unapproved_end_frame
blocked_upload_failed
blocked_cost_cap
failed_provider_error
failed_qa
needs_manual_review
```

## Agent-safe workflow

Recommended command sequence for coding agents:

```text
1. GET /automation/project/summary
2. GET /automation/scenes/{sceneID}/effective-shot-specs
3. POST /automation/references/resolve with dry_run
4. POST /automation/frame-plans/dry-run
5. Save contract/plan only after dry-run passes
6. Generate one beginning frame only
7. Approve variant manually or via explicit test fixture
8. Generate end frame
9. Queue video only after both frames are approved
10. Run QA
```
