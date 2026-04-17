# Amira Writer Handoff — LoRA Queue / RunPod Hardening / Live Pricing

Date: 2026-04-10  
Workspace: `/Volumes/Storage VIII/Programming/Amira Writer`

## Source Of Truth

- Start with:
  - `/Volumes/Storage VIII/Programming/Amira Writer/history/HANDOFF-2026-04-06-LORA-RUNPOD-AMIRA-WRITER.md`
- Then use this handoff for everything completed in the current thread.

## Critical User Constraints

- All Imagine scenes and LoRA validation prompts must stay **photorealistic**.
- **Do not use SymDex.**
- **Never control applications on this laptop.** App launching/UI control must happen only on `Garys-Server.local`.
- **Builds must happen on the server.** Deploy only to:
  - `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`
- The synced laptop copy may show a stale Finder timestamp; check the inner binary timestamp instead.

## What Was Completed In This Thread

### 1) LoRA recovery and persistence were hardened

Implemented a much more resilient RunPod LoRA lifecycle in `RunPodLORAService`:

- persisted active LoRA job state to disk
- recovered jobs across app restarts
- recovered older heartbeat-only jobs from the RunPod watchdog temp file
- parsed raw `training.log` step lines directly, not only custom progress markers
- preserved active pods on SSH transport drops and resumed automatically instead of immediately treating them as dead
- stopped auto-terminating active LoRA runs on app quit/save paths

This fixed the earlier restart case where a live LoRA pod existed but the UI came back as empty or `0/3000`.

### 2) Final artifact handling was hardened so completed runs are much harder to lose

Implemented several protections around the expensive “training finished but download failed” path:

- final `.safetensors` now downloads to a **temporary local file** first
- remote file size is checked before download
- downloaded local file size must match the remote size before promotion to final path
- final download retries multiple times with reconnect/re-resolution of pod connection details
- if the final download still fails, the app now **preserves the pod for automatic recovery** instead of terminating it immediately
- the previous local LoRA is now archived **only after** the new LoRA has been downloaded successfully

This addresses the specific repeated money-burning failure where a finished training run could still be lost by a single SCP/download failure.

### 3) Existing LoRAs are now archived before replacement

When a new LoRA completes for a character:

- the old canonical file is moved into:
  - `Animate/characters/<slug>/lora/archive/`
- the new LoRA then becomes the canonical active file

Result:

- `rig.json` and downstream syncs keep a stable “current” filename
- old versions are preserved instead of silently overwritten

### 4) The photoreal 50-candidate Gemini LoRA pipeline was implemented

Implemented a new photoreal candidate-generation flow for character LoRA datasets:

- **real lifestyle references only**
- no reference/master-sheet training path in this workflow
- **50 photoreal Gemini-generated candidates** for LoRA training
- unique random trigger-token workflow
- photoreal class-based caption templates carried with generated candidates
- intended for curated identity/body/story-world coverage before 3000-step LoRA training

Important user preference confirmed in this thread:

- this LoRA workflow is for **real-life inspiration images**, not anime/stylized sheets

### 5) Gallery LoRA selection and status UX were repaired

Fixed several gallery and training-selection issues:

- deduped mixed absolute-vs-relative path selections so the app stopped overcounting selected LoRA images
- restored missing LoRA checkbox visibility after the absolute/relative mismatch bug
- added gallery filters for:
  - All
  - Gemini
  - LoRA
  - Hidden
- added live filtered removal behavior so items disappear immediately when unselected while filtered
- added thumbnail-size controls in the gallery

### 6) Gemini batch status handling was improved

Improved Gemini batch-state handling so the app no longer misleadingly equates “downloaded image count” with true provider-side progress:

- exposed provider update timestamps/status fields
- stopped showing a fake `0/N` when Gemini only exposed a running batch with no partial completion count
- improved detection of completed/imported batch results already present on disk

### 7) Cleared status rows now stay cleared

Fixed the bug where some cleared status items came back after relaunch:

- Gemini batch rows are rediscovered from disk, so removing them only from memory was not enough
- added persisted dismissal/tombstone keys so cleared terminal rows stay gone across refresh/relaunch

### 8) Added a serial overnight LoRA queue

Implemented a persisted **single-worker LoRA queue**:

- `Start Now` button for immediate training
- `Queue` button to enqueue another LoRA job
- queued jobs appear in the same `Image Generation Status` area
- jobs run **one at a time only**
- the next queued job starts **only after a successful completion**
- failed/cancel-like terminal states pause the queue instead of burning through the rest overnight
- queued jobs and recent completed jobs are persisted across relaunches

This explicitly does **not** run multiple RunPod LoRA pods at once.

### 9) 9B support was added and remains the default

Current LoRA base-model setup in Amira Writer is now:

- `FLUX.2 Klein 4B Base`
- `FLUX.2 Klein 9B Base`

Important mapping:

- `4B` -> `NVIDIA RTX A6000`
- `9B` -> `NVIDIA A100 80GB PCIe`

Important user clarification from this thread:

- **9B should remain the default**
- do **not** revert the default back to 4B just because it is cheaper

### 10) Rank controls were upgraded

Network-rank control is no longer a tiny stepper.

Available rank options are now:

- `32`
- `64`
- `128`
- `256`

And `networkAlpha` auto-syncs to half the rank:

- `32 -> 16`
- `64 -> 32`
- `128 -> 64`
- `256 -> 128`

Current default remains:

- rank `64`
- alpha `32`

### 11) RunPod account balance and live GPU pricing UI were added

Added RunPod account/billing UI under API Settings -> RunPod:

- account funds left
- current spend per hour
- minimum-balance/under-balance warning
- refresh button

Also added **live RunPod GPU pricing** display for:

- `NVIDIA RTX A6000`
- `NVIDIA A100 80GB PCIe`

And the LoRA sheet now shows the selected base model’s live pricing inline.

Important caveat discovered during shell-side verification:

- the stored RunPod API key returned `403 Forbidden` to direct GraphQL checks from the shell
- the UI therefore needs to be treated as the current user-facing source of truth for whether the saved key can successfully fetch pricing/balance
- if refresh fails, the UI should surface the auth failure explicitly rather than assuming low balance

### 12) Z-Image was explored and then removed from Amira Writer

There was a temporary branch where Z-Image Turbo was added as an alternate managed-trainer target.

User decision:

- leave both `Z-Image Turbo` and `Z-Image Base` **out of Amira Writer for now**

Current app should therefore only expose the two FLUX options above.

## Verified Character LoRA State

From project `rig.json` data at the end of this thread:

### Mark Price

- Active LoRA file:
  - `mrkp43-flux2-klein-base-9b.safetensors`
- Trigger word:
  - `mrkp43`

### Matt Quill

- Active LoRA file:
  - `mttq39-flux2-klein-base-9b.safetensors`
- Trigger word:
  - `mttq39`

### Amira Nazari

- No active LoRA file recorded yet in `rig.json`
- `activeLORAWeight` exists, but no completed active filename/trigger is present yet

## Important Files Changed During This Thread

### Core LoRA / RunPod

- `Packages/Animate/Sources/AnimateUI/Services/RunPodLORAService.swift`
- `Packages/Animate/Sources/AnimateUI/Models/LORATrainingModels.swift`

### LoRA sheet / status UI / gallery

- `Packages/Animate/Sources/AnimateUI/Views/LORATrainingSheet.swift`
- `Packages/Animate/Sources/AnimateUI/Views/ImagineCharactersPageView.swift`
- `Packages/Animate/Sources/AnimateUI/Models/ImagineGalleryState.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`

### API settings / RunPod balance + pricing

- `Packages/Animate/Sources/AnimateUI/Views/GeminiSettingsSheet.swift`
- `Packages/Animate/Sources/AnimateUI/Services/RunPodAccountService.swift`

### Supporting docs / guidance

- `/Volumes/Storage VIII/Programming/UI Lessons/SWIFT_UI_MASTER_GUIDE.md`

## Current Deploy State

Latest deployed app bundle:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Verified timestamps:

- App bundle:
  - `2026-04-10 01:46:22 PDT`
- Binary:
  - `2026-04-10 01:46:23 PDT`

## Recommended Next Steps

1. Relaunch the latest app build from `!Applications`.
2. Open `API Settings -> RunPod` and hit `Refresh`.
3. Verify whether the saved RunPod key now returns:
   - real balance/pricing, or
   - a visible auth failure
4. In the LoRA sheet, verify the live hourly pricing line for the selected model.
5. Verify the serial queue on a real overnight run:
   - queue two jobs
   - let the first succeed
   - confirm the second starts automatically
6. Tomorrow, if Gary still wants stronger artifact guarantees, implement one of these storage layers:
   - RunPod network volume for `/workspace`
   - external object-storage upload for final artifacts/checkpoints

## Prompt For The Next Session

> We are continuing work in `/Volumes/Storage VIII/Programming/Amira Writer`. First read `/Volumes/Storage VIII/Programming/Amira Writer/history/HANDOFF-2026-04-06-LORA-RUNPOD-AMIRA-WRITER.md` and `/Volumes/Storage VIII/Programming/Amira Writer/history/HANDOFF-2026-04-10-LORA-QUEUE-RUNPOD-PRICING.md`. Use them as source of truth. Important constraints: all Imagine scenes and LoRA validation prompts must be photorealistic; do not use SymDex; never control applications on this laptop; server-only builds/deploys to `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`. Current LoRA targets are FLUX.2 Klein 4B and 9B only. 9B remains the default. 4B maps to A6000, 9B maps to A100 80GB PCIe. The app now has serial LoRA queueing, hardened final artifact download/recovery, gallery filters/thumbnail controls, balance/pricing UI, and fixed non-returning clears for status rows. Next, verify the live RunPod balance/pricing UI with the actual saved key and continue hardening/using the LoRA queue and storage strategy as needed.
