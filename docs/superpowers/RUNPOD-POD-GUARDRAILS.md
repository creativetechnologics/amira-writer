# RunPod Pod Guardrails

Use `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/runpod_pod_monitor.py`
before any Amira Writer RunPod session.

## Commands

- `python3 Scripts/runpod_pod_monitor.py ensure-monitor`
  - starts the background stale-pod monitor if it is not already running
- `python3 Scripts/runpod_pod_monitor.py status`
  - shows monitor PID, current heartbeat/pod registration, and log path
- `python3 Scripts/runpod_pod_monitor.py reap-now`
  - immediately terminates the registered pod if the heartbeat is stale
- `python3 Scripts/runpod_pod_monitor.py terminate <pod_id>`
  - manually terminates a specific pod

## How it works

- `RunPodLORAService` writes the legacy heartbeat file at
  `$TMPDIR/amira-runpod-watchdog.json` once per minute while a training pod is active.
- Newer RunPod-backed features can register their own heartbeat files under:
  - `$TMPDIR/amira-runpod-watchdogs/*.json`
- The monitor scans both the legacy file and the per-feature heartbeat directory.
- The monitor treats that heartbeat as stale after 180 seconds and calls
  RunPod GraphQL `podTerminate` so billing stops if the app crashes or loses
  control of the pod.
- The monitor looks for the RunPod API key in:
  1. `RUNPOD_API_KEY`
  2. `~/.lora-maker/runpod_api_key`
  3. Keychain item `service=com.amira.writer.animate`, `account=runpod-api-key`

## Logs

- Monitor log: `~/Library/Logs/Amira/runpod_pod_monitor.log`
- App training log: `~/Library/Logs/Amira/runpod-lora.log`
- App MuseTalk log: `~/Library/Logs/Amira/runpod-mouth-sync.log`

Before ending a RunPod-related task, verify:

1. `python3 Scripts/runpod_pod_monitor.py status`
2. no active pod remains unless explicitly intended
3. the app or the manual cleanup command has terminated the pod
