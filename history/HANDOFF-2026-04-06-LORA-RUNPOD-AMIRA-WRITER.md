# Amira Writer Handoff — LoRA / RunPod / Draw Things

Date: 2026-04-06  
Workspace: `/Volumes/Storage VIII/Programming/Amira Writer`

## User Constraints

- All **Imagine** scenes and validation prompts must be **photorealistic**.
- User explicitly said: **DO NOT USE SYMDEX**.
- For RunPod work, use the repo-local watchdog:
  - `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/runpod_pod_monitor.py`

## What Was Completed

### 1) Built project-local LoRA storage + use

Implemented a per-character LoRA flow so Amira Writer can:

- store trained/imported LoRAs under:
  - `Animate/characters/<character-slug>/lora/`
- persist the active LoRA mapping in the character rig JSON
- let the character own:
  - active LoRA filename
  - trigger word
  - weight
- sync the active LoRA into Draw Things automatically
- auto-apply that LoRA when an Imagine prompt mentions the character name

### 2) Full live RunPod end-to-end run completed successfully

Character: **Luke Hart**  
Selected images: **29**  
Completed run steps: **1500 / 1500**

Artifacts created:

- Project LoRA:
  - `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/characters/luke-hart/lora/luke.safetensors`
- Draw Things synced LoRA:
  - `/Volumes/Storage XI/AI Models/Draw Things/amira__luke-hart__luke.safetensors`
- Generated smoke-test image:
  - `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/imagine/scenes/lora-smoke-test/shot-001/beginning/dt_1775502480726_0.png`
- Prompt sidecar:
  - `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/imagine/scenes/lora-smoke-test/shot-001/beginning/dt_1775502480726_0.prompt.txt`

Rig mapping verified in:

- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/characters/luke-hart/rig.json`

Verified fields:

- `activeLORAFilename = "luke.safetensors"`
- `activeLORATriggerWord = "luke"`
- `activeLORAWeight = 1`

### 3) Smoke-test prompt bug fixed

The original headless LoRA smoke test was wrong because it used an **anime** prompt.  
That was fixed so the default validation prompt is now photoreal.

### 4) Character gallery thumbnail bug fixed

Bug reported by Gary:

- all character thumbnails initially showed **Luke’s** thumbnails
- selecting a character corrected the preview pane, but not the initial gallery state

Cause:

- SwiftUI grid items were keyed by **index**, so stale thumbnail view state was reused across characters

Fix:

- key gallery items by image path
- clear/reload cached thumbnail state when the path changes

### 5) LoRA training is now hard-coded to 3000 steps

Gary confirmed the 1500-step Luke result was not good enough and requested that all future character LoRA training always use **3000** steps.

Implemented:

- central enforcement of **3000** steps in the training model
- training sheet no longer offers lower-step presets
- CLI / automation still accept `--preset` for compatibility, but override to **high / 3000**

## Important Files Changed

### LoRA storage / selection / use

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/DrawThingsLoRAService.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Views/LORATrainingSheet.swift`

### Headless automation / CLI

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/AnimateAutomation.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/Animate/AnimateMain.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/RunPodCredentialStore.swift`

### RunPod / watchdog / docs

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Services/RunPodLORAService.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/runpod_pod_monitor.py`
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/superpowers/RUNPOD-POD-GUARDRAILS.md`

### Latest fixes in this last phase

- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Views/CachedThumbnailView.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Models/LORATrainingModels.swift`
- `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Animate/Sources/AnimateUI/Views/ImagineInspectorView.swift`

## Current Deploy State

Latest deployed app bundle:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Verified timestamps:

- App bundle:
  - `2026-04-06 15:20:49 PDT`
- Binary:
  - `2026-04-06 15:20:50 PDT`
- Animate bundle:
  - `2026-04-06 15:20:49 PDT`

## Garys-Laptop.local Verification

Verified on `Garys-Laptop.local`:

- Correct app location:
  - `~/Programming/!Applications/Amira Writer.app`
- Laptop binary timestamp:
  - `2026-04-06 15:20:50 PDT`
- Server binary timestamp:
  - `2026-04-06 15:20:50 PDT`
- SHA-256 matches exactly:
  - `a26792a2d2c93f98ab369bb8b90a117157de776093e8998cf30feaf5e83a8500`

Important note:

- the **top-level `.app` folder timestamp on the laptop is stale**
- but the **inner executable is current**
- Finder may make the app look old even when the binary is updated

No duplicate installs found in:

- `~/Applications/Amira Writer.app`
- `~/Applications/Novotro Write.app`

## Current Reality / Outstanding Work

The code path is now in much better shape, but the **Luke LoRA itself is not yet good enough** for production-quality photoreal use.

Why:

- completed Luke training run used **1500** steps
- user judged the result poor
- user then explicitly requested all future runs be **3000** steps

So the next real product step is:

1. relaunch the new synced app on the target machine
2. confirm the thumbnail fix is visible in UI
3. start a new **Luke Hart** LoRA run at **3000** steps
4. validate only with **photoreal** prompts
5. check whether the new 3000-step LoRA is materially better

## Useful Commands / Checks

### Build + deploy

```bash
rtk /Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-app.sh --debug
```

### Fast local build

```bash
rtk /Volumes/Storage VIII/Programming/Amira Writer/Scripts/build-opera-dev.sh
```

### Check deployed timestamps

```bash
rtk stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S %Z' \
  '/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app' \
  '/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera' \
  '/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app/Contents/Resources/Animate_AnimateUI.bundle'
```

### Check laptop binary timestamp

```bash
rtk ssh gary@Garys-Laptop.local 'stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S %Z" "$HOME/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera"'
```

### Check laptop binary hash

```bash
rtk ssh gary@Garys-Laptop.local 'shasum -a 256 "$HOME/Programming/!Applications/Amira Writer.app/Contents/MacOS/Opera"'
```

## Prompt For The Next Codex Session

Use this prompt on the other machine:

> We are continuing work in `/Volumes/Storage VIII/Programming/Amira Writer`. First read `/Volumes/Storage VIII/Programming/Amira Writer/history/HANDOFF-2026-04-06-LORA-RUNPOD-AMIRA-WRITER.md` and use it as the source of truth. Important constraints: all Imagine scenes and LoRA validation prompts must be photorealistic, and do not use SymDex. The latest app bundle is `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`, and Garys-Laptop.local already has the latest synced binary even if Finder shows a stale app timestamp. The recent work added project-local LoRA storage/use, Draw Things auto-LoRA application, a headless RunPod E2E path, fixed the bad anime smoke prompt, fixed the gallery thumbnail bug, and hard-coded LoRA training to 3000 steps. Please pick up by verifying the new build in the UI, then do the next Luke Hart retrain at 3000 steps and validate it with photoreal prompts only.
