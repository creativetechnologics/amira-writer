# 05 — Shot Frame and Video Handoff

## Internal frame model

Keep `beginning / middle / end` internally, but expose `start / end` to video generation.

```text
beginning = video start frame
middle    = optional continuity / QA / split frame
end       = video end frame
```

Reasons:

- Video generators usually want start/end.
- Middle frames improve continuity, QA, and edit-mode planning.
- Longer shots can be split into multiple start/end video tasks.
- Middle can become either a QA checkpoint or split point.

## Generate vs edit rules

| Condition | Mode |
|---|---|
| First frame of shot | Usually fresh `generate` |
| Same place, same angle, same characters | `edit` from previous approved frame |
| End frame with same composition | `edit` from beginning or middle |
| Character expression/action change only | `edit` |
| Camera hard cut | fresh `generate` |
| New place | fresh `generate` |
| Major time jump | fresh `generate` |
| New character enters but composition same | edit if source can support it; otherwise generate |
| Storyboard frame exists | use storyboard as layout authority |
| No readable source image for edit | fail visibly; do not silently degrade |

## Open-matte strategy

Use open-matte generation to gain camera control:

1. Generate a wider/taller plate, e.g. 4:3.
2. Extract 16:9 frames for video.
3. Preserve 21:9 delivery headroom.
4. Simulate pans/tilts/zooms through deterministic crop keyframes.
5. Store crop rectangles in the plan sidecar.

Example:

```json
{
  "version": 1,
  "generatedAspectRatio": "4:3",
  "generatedImageSize": "4K",
  "extractionTargetAspectRatio": "16:9",
  "finalDeliveryAspectRatio": "21:9",
  "intendedCameraShot": "medium",
  "generatedCameraShot": "wide",
  "cropMotion": "pan_right",
  "cropKeyframes": [
    {
      "moment": "beginning",
      "cropRect": { "x": 0.08, "y": 0.18, "width": 0.84, "height": 0.63 }
    },
    {
      "moment": "end",
      "cropRect": { "x": 0.12, "y": 0.18, "width": 0.84, "height": 0.63 }
    }
  ]
}
```

## Frame generation sidecars

Every paid frame job must write:

```text
image file
prompt.txt
response.txt
plan.json
reference-contract.json or pointer
qa.json when QA runs
approval metadata
```

## Video handoff

A video task should not queue until:

```text
- start/beginning frame exists
- end frame exists
- both are approved or explicitly auto-approved
- public URLs are available or upload service succeeds
- motion prompt exists
- cost cap allows the task
```

## Provider upload abstraction

Add a protocol:

```swift
protocol FrameUploadService {
    func uploadFrame(localPath: URL) async throws -> URL
}
```

Use this to support Vidu or future providers without hard-coding one upload path.

## Video duration policy

| Shot type | Video strategy |
|---|---|
| Simple action/reaction | 4s start/end task |
| Dialogue beat | 4s or 8s task |
| Longer movement | Split into multiple 4s/8s tasks |
| Major camera move | Prefer open-matte crop or split shots |
| Complex geography/action | Generate middle frame and split |

Do not push long, complex shots into a single video generation unless start/middle/end have been approved.

## Video task record

```json
{
  "version": 1,
  "shotID": "...",
  "sceneID": "...",
  "provider": "vidu",
  "providerModel": "vidu2.0",
  "startFramePath": "/absolute/start.png",
  "endFramePath": "/absolute/end.png",
  "startFramePublicURL": "https://...",
  "endFramePublicURL": "https://...",
  "motionPrompt": "clear physical motion between start and end",
  "durationSeconds": 4,
  "resolution": "1080p",
  "movementAmplitude": "auto",
  "taskID": "provider-task-id",
  "status": "queued | generating | succeeded | failed",
  "outputPath": "/absolute/output.mp4",
  "qaStatus": "untested | pass | fail | needs_review",
  "attempt": 1
}
```

## Resume behavior

- Store task records before calling provider APIs.
- After app restart, scan `Animate/video-tasks`.
- Resume polling tasks with `queued` or `generating`.
- Failed tasks remain inspectable and retryable.
- Retried tasks increment `attempt` and preserve previous records.
