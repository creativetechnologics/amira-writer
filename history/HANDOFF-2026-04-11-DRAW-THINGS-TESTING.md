# Amira Writer Handoff — Draw Things Prompt Cleanup / Server-Side Testing

**Date:** 2026-04-11  
**Workspace:** `/Volumes/Programming/Amira Writer`

## Goal

Continue the Draw Things / FLUX.2 [klein] testing work on **Garys-Server.local** only, with focus on:

- better character consistency
- cleaner skin rendering
- prompt variety across test shots
- guaranteed canvas clearing before each new generation
- keeping prompts short, literal, and name-free

## User constraints to preserve

- Do **not** run Draw Things on the laptop.
- Prefer server-side testing on **Garys-Server.local**.
- Do **not** include human character names in prompts sent to Draw Things.
- Keep prompts descriptive, not emotional or story-heavy.
- Clear the canvas before every generation.
- If the prompt engine needs a fallback, keep it simple and blocking-focused.

## What is already true in the app code

### Scene prompt generation is already moving in the right direction

`ImagineScenePromptService` already:

- targets FLUX.2 [klein] explicitly
- uses short prompts
- preserves left/right blocking
- avoids human names
- prefers `lkhr27` / neutral subject tokens for the prompt pipeline

Relevant file:

- `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift`

### Scene sweep hardening already exists

`AnimateSceneSweepAutomation` already adds guardrails for:

- ghost people
- partial people
- duplicate bodies
- double exposure
- extra limbs

Relevant file:

- `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneSweepAutomation.swift`

### Model defaults are already aligned

The scene workflow already defaults to **Flux.2 Klein 9B**.

Relevant file:

- `Packages/Animate/Sources/AnimateUI/Models/ImagineModels.swift`

## What changed during this session on the Draw Things script

The server-side Draw Things script is here:

- `/Users/gary/Library/Containers/com.liuliu.draw-things/Data/Documents/Scripts/amira-inspiration-b.js`

I successfully changed only the canvas-clear timing constants so far:

- `CANVAS_CLEAR_TIMEOUT_SECONDS = 7`
- `CANVAS_CLEAR_STABLE_POLLS = 2`
- `MAX_CANVAS_CLEAR_ATTEMPTS = 3`

## What did **not** land yet

The following planned changes were **not** successfully applied yet:

- `NEGATIVE_PROMPT` is still empty in the script
- `OUTPUT_SUBDIRECTORY` is still the old relative path:
  - `DrawThings/AmiraInspiration`
- `buildSavePath()` still does not support an absolute Desktop output path
- `canvas.clear()` is still only the simple one-call version, not a stronger retry wrapper
- prompt-variety tokens for skin/composition/blocking have not yet been added to the script

## Live issue discovered

When I checked the Draw Things port from this workstation, `Garys-Server.local:7860` was refusing connections.

That means the next test pass probably needs to be done:

1. from the server-side Draw Things app itself, or
2. after confirming Draw Things is actually running and listening on the server

## Best next steps

1. Patch `amira-inspiration-b.js` on Garys-Server.local with:
   - a stronger negative prompt for splotchy / blotchy skin
   - a small positive skin-quality clause
   - a little prompt variety for single / pair / location shots
   - an absolute Desktop save path so results land in:
     - `/Users/gary/Desktop/Amira DT Ref Tests`

2. Add a stronger canvas reset helper so every generation:
   - clears
   - waits for empty canvas
   - retries if the canvas still contains old content

3. Re-run a few test images on **Garys-Server.local** only.

4. If multi-character reference fidelity still fails in Flux 2 Klein 9B, consider the fallback workflow:
   - 0–1 characters: Flux 2 Klein 9B
   - 2+ characters: Gemini / reference-image workflow

## Important files to resume from

- `Packages/Animate/Sources/AnimateUI/Services/ImagineScenePromptService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/ImagineGenerationService.swift`
- `Packages/Animate/Sources/AnimateUI/Services/AnimateSceneSweepAutomation.swift`
- `Packages/Animate/Sources/AnimateUI/Views/DrawThingsGenerationPane.swift`
- `/Users/gary/Library/Containers/com.liuliu.draw-things/Data/Documents/Scripts/amira-inspiration-b.js`

## Notes from this session

- The user explicitly asked to stop the current work and switch to a handoff doc.
- I aborted the background search commands so they should no longer be the active focus.
- The remote Draw Things script is still only partially updated, so the next session should treat it as unfinished.


---

## 2026-04-11 Addendum — reference-image control-input testing

### Updated conclusion

The proper **fresh-image** reference workflow is **not** HTTP `img2img` with a collage on the canvas.

Official Draw Things source code indicates:

- HTTP `img2img` only really takes a single `init_images` image.
- reference / moodboard images map to **`shuffle` hints**.
- for app-side scripting, Draw Things exposes moodboard APIs such as:
  - `canvas.clear()`
  - `canvas.addToMoodboardFromFiles()` / `loadMoodboardFromFiles()`
  - `pipeline.run(...)`

### What was actually tested successfully

I ran a direct local Draw Things pipeline test against the model stack in:

- `/Volumes/Storage XI/AI Models/Draw Things`

using the latest Luke reference folder:

- `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Animate/characters/luke-hart/inspiration-batches/20260407T050847392Z-photoreal-lora-candidates/results`

with **moodboard/shuffle reference inputs** and **no init canvas image**.

This produced new outputs copied to:

- `/Users/gary/Desktop/Amira DT Ref Tests/dt-moodboard-sdxl-ipface-seed424242-steps6.png`
- `/Users/gary/Desktop/Amira DT Ref Tests/dt-moodboard-sdxl-ipplus-seed424243-steps6.png`
- `/Users/gary/Desktop/Amira DT Ref Tests/dt-moodboard-sdxl-ipplus-seed424244-steps6-wideprompt.png`

Matching prompt files were also written beside each PNG.

### Result quality

- These runs **do** generate brand-new images instead of echoing the collage.
- The likeness transfer is noticeably better than the broken collage-echo runs.
- However, with SDXL + IP-Adapter control, prompt adherence is still weak: the outputs stay portrait-biased and do not yet honor the requested alley / wider-shot composition strongly enough.

### Most useful next tuning direction

The next pass should tune **identity-vs-composition balance**, likely by varying:

- IP-Adapter model choice (`plus` vs `plus face`)
- control weight
- seed
- model choice for prompt following
- shot framing / aspect ratio

while keeping the hard rules:

- no cropped refs
- no canvas init image
- fresh generation each time
- outputs copied to Desktop
