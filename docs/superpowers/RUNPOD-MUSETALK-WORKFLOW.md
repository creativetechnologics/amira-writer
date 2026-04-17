# RunPod MuseTalk Workflow

This document describes the first-pass RunPod workflow for neural mouth sync using
`MuseTalk 1.5` inside Amira Writer.

## Current Scope

- Single visible speaking face per clip
- Single source video input
- Single audio input
- Ephemeral RunPod pod
- No network storage yet
- Model weights are downloaded fresh on every run

## Safety Rules

- Always ensure the repo-local watchdog is running before creating or resuming a pod:
  - `python3 Scripts/runpod_pod_monitor.py ensure-monitor`
- Every active MuseTalk pod must write a heartbeat file under:
  - `$TMPDIR/amira-runpod-watchdogs/musetalk-inference.json`
- Pods must be terminated on:
  - successful completion
  - any fatal error
  - app relaunch recovery
- If the app crashes, the watchdog must reap the pod when the heartbeat goes stale.

## Pod Shape

- Container image:
  - `runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04`
- Recommended first GPU:
  - `NVIDIA RTX 4090`
- Heavier fallback GPUs:
  - `NVIDIA A40`
  - `NVIDIA L40S`
- Container disk:
  - 80 GB on 4090
  - 100 GB on A40 / L40S

## Remote Bootstrap

The bootstrap script should:

1. install system packages required for video + OpenCV inference
2. create a Python environment
3. clone `https://github.com/TMElyralab/MuseTalk.git`
4. install the inference dependencies
5. install `mmengine`, `mmcv==2.0.1`, `mmdet==3.1.0`, `mmpose==1.1.0`
6. run `download_weights.sh` when weights are missing

## Remote Inference

The inference script should:

1. normalize the input video to 25 fps
2. normalize the audio to 16 kHz mono WAV
3. write a temporary MuseTalk inference YAML config
4. run `python -m scripts.inference` with `--version v15`
5. verify the output exists at:
   - `/workspace/output/v15/amira_musetalk_output.mp4`

## Local Lifecycle

The `RunPodMouthSyncService` should persist:

- active job snapshot:
  - `~/Library/Application Support/Amira/active-runpod-mouth-sync-job.json`
- recent jobs:
  - `~/Library/Application Support/Amira/recent-runpod-mouth-sync-jobs.json`
- feature log:
  - `~/Library/Logs/Amira/runpod-mouth-sync.log`

## Roadmap

- Add network storage so weights persist across runs
- Support resuming in-flight inference instead of terminating on recovery
- Integrate the service into the main mouth-sync UI flow
- Add speaker/face selection when the source clip contains multiple faces
