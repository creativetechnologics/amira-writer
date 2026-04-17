# Amira Writer Handoff — Mouth Sync / RunPod / MuseTalk

Date: 2026-04-10 15:54  
Workspace: `/Volumes/Storage VIII/Programming/Amira Writer`

## User Constraints

- Keep going until quality improves materially; do not stop at analysis only.
- Use a real moving-face clip for validation, not just the Abraham Lincoln still-photo video.
- Use RunPod with the same safety rules as the LoRA Maker workflow:
  - repo-local watchdog
  - no lingering pods
  - terminate on error / completion
  - recover safely after crashes / relaunches
- For now, do **not** use RunPod network storage.
- Download MuseTalk models fresh on every run for now.

## What Was Completed

### 1) Local mouth-sync pipeline bugfix pass

The original local mouth-sync system failed in multiple ways. The following were fixed:

- Vision lip landmarks were being interpreted in the wrong coordinate space.
  - `VNFaceLandmarkRegion2D.normalizedPoints` are normalized inside the face bounding box, not the whole frame.
  - This was the root cause of the mouth warp landing in the beard / bow-tie area.
- Export resolution mismatch was fixed.
  - Source landmark detection and render output now use compatible dimensions via `.source` resolution support.
- The compositor was changed to sample from an immutable source frame instead of warping in place.
  - The in-place warp was causing the gray smear / blob failure.
- The coarse ellipse mouth warp was replaced with a contour-based outer+inner lip warp with feathered blending.
- Temporal smoothing was added to tracked face boxes and lip landmarks to reduce jitter.

### 2) Real moving-face validation clip added

A public-domain talking-head clip was downloaded and used for validation:

- Source clip:
  - George W. Bush speech archive clip from Archive.org
- Local derived files:
  - `/tmp/mouth-sync-test/bush_state_union.mp4`
  - `/tmp/mouth-sync-test/bush_state_union_30s.mp4`
  - `/tmp/mouth-sync-test/bush_state_union_30s.m4a`

Generated desktop demos include:

- `/Volumes/Storage VIII/Users/gary/Desktop/mouth_synced_bush_state_union_30s.mp4`
- `/Volumes/Storage VIII/Users/gary/Desktop/mouth_synced_bush_state_union_30s_v4_audio.mp4`
- `/Volumes/Storage VIII/Users/gary/Desktop/mouth_synced_bush_state_union_30s_v5.mp4`
- `/Volumes/Storage VIII/Users/gary/Desktop/mouth_synced_bush_state_union_30s_v6_smoothed.mp4`
- `/Volumes/Storage VIII/Users/gary/Desktop/mouth_synced_lincoln_60s_v6.mp4`

### 3) Realism ceiling identified for geometry-only warp

After frame extraction and inspection of actual rendered results, the conclusion is:

- the catastrophic placement / blob bugs were fixed
- the latest local contour warp is materially better than the original failure
- but a pure landmark-driven geometric warp still does **not** meet the “indistinguishable from original” bar

Research pointed to a neural mouth-synthesis approach as the correct next step.

### 4) MuseTalk chosen as the next-step neural workflow

Research compared practical options and landed on `MuseTalk 1.5` as the best next frontier move because:

- it is a real pretrained audio-driven lip-sync model
- it supports unseen identities
- it uses latent-space face-region inpainting rather than simple geometry warping
- its docs and model licensing path are more suitable than the open-source Wav2Lip path for future product use

### 5) First-pass RunPod MuseTalk backend built

Implemented a new RunPod-backed MuseTalk workflow modeled after the existing LoRA Maker flow.

Added:

- `Packages/Animate/Sources/AnimateUI/Models/RunPodMouthSyncModels.swift`
- `Packages/Animate/Sources/AnimateUI/Services/RunPodMouthSyncService.swift`

What the new service does:

- uses the shared `RunPodCredentialStore`
- creates an on-demand RunPod pod with SSH via `PUBLIC_KEY`
- ensures the repo-local watchdog monitor is running before pod creation
- uploads source video and audio
- bootstraps MuseTalk on the pod
- downloads model weights fresh on every run
- runs MuseTalk 1.5 inference
- downloads the rendered mp4 locally
- terminates the pod on success
- terminates the pod on fatal error
- terminates recovered in-flight MuseTalk pods on app relaunch for safety

Current scope of this backend:

- single visible face
- single source video
- single audio source
- ephemeral pod only
- no network storage yet

### 6) RunPod watchdog generalized for multiple features

The old watchdog only handled the LoRA heartbeat file. It now supports:

- legacy heartbeat:
  - `$TMPDIR/amira-runpod-watchdog.json`
- per-feature heartbeats:
  - `$TMPDIR/amira-runpod-watchdogs/*.json`

This allows LoRA and MuseTalk RunPod features to coexist safely.

### 7) Workspace integration added

`AnimateWorkspace.swift` now aggregates RunPod activity across:

- `RunPodLORAService`
- `RunPodMouthSyncService`

So the workspace-level RunPod indicator / emergency stop can cover both workflows.

### 8) New docs added / updated

Added:

- `/Volumes/Storage VIII/Programming/Amira Writer/docs/superpowers/RUNPOD-MUSETALK-WORKFLOW.md`

Updated:

- `/Volumes/Storage VIII/Programming/Amira Writer/docs/superpowers/RUNPOD-POD-GUARDRAILS.md`

## Important Files Changed

### Local mouth-sync fixes

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/VideoMouthSync/MouthSpriteComposer.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/VideoMouthSync/VideoFaceTrackingService.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/VideoMouthSync/VideoMouthSyncPipeline.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/VideoMouthSync/VideoMouthSyncModels.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/VideoExporter.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Tests/AnimateTests/MouthSyncIntegrationTests.swift`

### New RunPod MuseTalk backend

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/RunPodMouthSyncModels.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/RunPodMouthSyncService.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/AnimateWorkspace.swift`

### RunPod safety + docs

- `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/runpod_pod_monitor.py`
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/superpowers/RUNPOD-POD-GUARDRAILS.md`
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/superpowers/RUNPOD-MUSETALK-WORKFLOW.md`

## Current Deploy State

Latest deployed app bundle:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

The app builds and deploys cleanly with the new MuseTalk RunPod backend included.

## Current Reality / Outstanding Work

### What is good now

- Local mouth-sync placement bugs are fixed.
- The Bush demo no longer has the obvious off-face blob failure.
- A first-pass RunPod MuseTalk backend exists and matches the LoRA Maker safety model closely.

### What is not done yet

- The MuseTalk workflow is **backend-only** right now.
- It is not yet wired into a visible app entry point.
- No live RunPod MuseTalk smoke test has been run yet.
- No network storage is attached yet; models are intended to download every run.

## Recommended Next Steps

1. Add a visible UI entry point for `RunPodMouthSyncService` in the existing mouth-sync flow.
2. Run a short real RunPod smoke test on the Bush clip.
3. Verify the pod is created, runs inference, downloads the output, and is always terminated.
4. After that works, optionally add cached model storage / network volume support as a second-phase optimization.

## Safety Notes

- No RunPod pods were launched during this implementation pass.
- There should be **no lingering pods** from this work.
- The generalized watchdog now supports both LoRA and MuseTalk heartbeat registration.
