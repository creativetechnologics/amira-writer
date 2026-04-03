# Character Reference Workflow — March 29, 2026

## Decision

Animate now moves toward a **master-sheet-first** character workflow:

1. Keep the existing **photorealistic inspiration image** area for each character.
2. Use those source images to generate **multiple master reference sheets**.
3. Approve the single best master sheet.
4. Use the approved master sheet to generate:
   - a **6-pose head turnaround**
   - a **6-pose full-body set per costume**
   - **accessories / props / gloves / gear**
5. Allow the user to replace any individual pose later without discarding older variants.

## Why

- The single master sheet is a strong compact reference for downstream Nano Banana 2 requests.
- Users can curate a best-of set instead of relying on one first-pass generation.
- Head likeness can be locked first, then reused to improve full-body costume generations.
- Costume changes are better represented as **one character identity with multiple costume sets**, not separate characters.

## UI / Workflow Requirements

- The Animate character page keeps the **realistic inspiration images** section.
- The reference workflow adds:
  - **Master Reference Sheet** area with multiple variants and approval
  - **6-pose head grid**
  - **6-pose full-body grid per costume**
  - **Accessory slots per costume**
- Each slot supports:
  - generate one
  - batch generate a set
  - keep old variants
  - approve a different variant later
  - replace a single pose without losing history

## Mandatory Preflight Rule

Before **any** Nano Banana 2 request is sent from Animate, the UI must open a preview pane that shows:

- exact prompt
- reference images being sent
- model
- aspect ratio
- image size
- estimated cost

The user can override any of those before the request is submitted.

## Current Luke Usage

Luke’s preferred master-sheet face reference is the March 29, 2026 **v2** anime reference sheet:

- `/Users/gary/Desktop/LORA Maker Samples/Luke Anime Reference Sheet 4K Test 2026-03-29 v2/luke-anime-reference-sheet-4k-v2-16x9.png`

The exact saved v2 generation settings were:

- model alias: `nano-banana-2`
- model: `gemini-3.1-flash-image-preview`
- image size: `4K`
- aspect ratio: `16:9`
- reference images used:
  1. `Packages/Animate/SampleData/CharacterPackages/LukePainterlyV1/gemini-batch-march20/luke-soldier-main.png`
  2. `/Users/gary/Desktop/LORA Maker Samples/Luke Anime-Leaning 5 1K Immediate 2026-03-29/03-03-prestige-tv-anime-realism-1k-21x9.png`

For Luke specifically, the app should preserve the **exact v2 prompt text** as the default master-sheet prompt with no wording drift.

## Additional Workflow Decisions

- The workflow must support **attaching an existing master reference sheet** instead of only generating a new one.
- When attaching an existing generated sheet, the app should recover the original **prompt / model / aspect ratio / image size** from adjacent saved metadata when available.
- The workflow must let the user choose **which inspiration images are included by default** in the master-sheet request.
- The preflight pane remains the final source of truth before sending, so users can still add/remove references there.

## Prompt Strategy For Other Characters

Do **not** use one identical Luke-style prompt for every character.

Best practice is:

1. keep one shared **master-sheet scaffold**
   - overall panel logic
   - clean studio background
   - same-character consistency rules
   - model-sheet formatting expectations
2. generate a **character-specific prompt block** for each character
   - identity traits
   - age / face / hair / body notes
   - costume notes
   - setting / era requirements
   - “avoid drift” rules

So Luke keeps the exact v2 prompt, while future characters should use the same sheet structure but a customized LLM-authored prompt derived from their own references and notes.

## Reference Count / Limits

Official Google Gemini docs confirm:

- multiple image inputs are supported in one prompt
- inline requests should stay under **20MB total request size**
- the Files API is recommended for larger or reusable media

So the product should encourage a **small curated reference set** rather than blindly sending every available image.

## Engine Framework Scaffold (March 29, 2026)

Animate now has an initial **engine framework scaffold** for the planned in-house / hybrid animation pipeline.

### What was added

- A persisted **scene automation profile** on each scene
- Engine configuration controls in the **Animate inspector**
- A computed **scene automation plan** that evaluates current readiness
- Per-character automation strategy and preferred costume routing

### New scene-level controls

- execution mode:
  - Auto Recommend
  - Animate Kit Only
  - Hybrid
  - Generative Assist
- acting intensity
- camera style
- lip-sync assist mode
- allow generative video assist
- automation pass toggles:
  - idle motion
  - blink pass
  - look-at
  - lip sync guide
  - camera assist
  - secondary motion
  - background parallax

### What the planner evaluates

For the currently selected scene, the planner now checks:

- approved master sheets
- approved 6-pose head turnarounds
- approved 6-pose full-body costume sets
- approved accessories
- active package / rig validity
- viseme coverage for dialogue automation
- scene complexity based on track/camera/action density

It then returns:

- recommended execution mode
- effective execution mode
- readiness score
- complexity score
- supported automation passes
- next recommended setup steps

### Important implementation note

This is a **framework scaffold**, not a full auto-animation engine yet.

It is meant to put the architecture in place now so later work can plug into:

- auto idle motion generation
- blink / look-at passes
- lipsync automation
- camera beat automation
- hybrid escalation to generative video for harder shots

### Files added / changed for the scaffold

- `Packages/Animate/Sources/AnimateUI/Models/SceneAutomationModels.swift`
- `Packages/Animate/Sources/AnimateUI/Services/SceneAutomationPlanner.swift`
- `Packages/Animate/Sources/AnimateUI/Models/AnimateModels.swift`
- `Packages/Animate/Sources/AnimateUI/AnimateStore.swift`
- `Packages/Animate/Sources/AnimateUI/Views/InspectorView.swift`

## Character Detail Pane UX

The character detail area now treats the major middle-column sections as **collapsible panes**:

- Character Notes
- Inspiration Images
- Character Reference Workflow
- Animated Images
- Character Packages

This keeps the workflow manageable as more per-character asset systems are added.

## Gallery Responsiveness Follow-Up

The character detail image galleries were improved to feel less rudimentary:

- gallery thumbnails now use the shared thumbnail cache instead of decoding full images in every tile body
- thumbnail cache keys now include the requested size
- thumbnail generation now uses ImageIO thumbnail creation instead of loading full-size images first
- gallery tiles now support a visible **selected** state with highlight/border/checkmark styling

This was done specifically to make the middle-column inspiration gallery feel less laggy and more intentional.

## Native Quick Look On Double-Click

For the main character-detail image galleries, double-click now prefers a **native macOS Quick Look preview panel** instead of only relying on the custom in-app overlay.

- if the file paths resolve cleanly, Quick Look opens natively
- if not, the old in-app overlay remains as fallback

This gives a much more Mac-like preview experience without needing to redesign the in-app `x / < / >` controls first.

## Gemini Settings Entry Point

Animate now has a visible **Gemini** settings button in the top workspace header.

- clicking it opens a **Gemini Settings** sheet
- the sheet includes:
  - Gemini API key entry
  - default Gemini model selection
  - clear/save controls
- the Gemini API key is stored locally in the **macOS Keychain**
- the default model is persisted in `UserDefaults`

This fixes the earlier issue where Animate had generation features wired up but no obvious UI for entering the Gemini key.

## Section Sheets + Inspiration Generation (March 29, 2026 late night)

The character-reference workflow now treats the **head turnaround** and **each costume set** as their own sheet-driven systems:

- Head Turnaround has its own square **2x3 master sheet** flow
- Every costume set has its own square **2x3 full-body sheet** flow
- Choosing or importing an approved section sheet now automatically **crops the six slot images** from that sheet
- Individual missing poses can still be generated afterward with Nano Banana 2

### 2x3 crop layout

Used for both the head sheet and each costume sheet:

- Row 1: front / quarter-left / quarter-right
- Row 2: back / left profile / right profile

This is the current production assumption for auto-cropping.

## Master Sheet / Prompt UX Updates

- Master-sheet variants now use **Choose** / **Chosen** instead of Approve / Approved
- The workflow now includes prompt-view controls with an eye-circle icon so the user can inspect the exact prompt used for a generation
- The Gemini preflight reference-image row was tightened into fixed square thumbnails to avoid the overlapping thumbnail issue

## Character Page Image UX Updates

The character page now supports more direct image management:

- **drag and drop from Finder** into the inspiration gallery
- drag and drop from Finder into the animated-image gallery
- drag and drop from Finder into the main reference image area
- drag and drop from Finder into the reference-image gallery
- double-click in the Inspiration Gallery sheet and Reference Images sheet now opens **native Quick Look** instead of only using the in-app overlay

## Inspiration Image Generation Flow

The Inspiration Images pane now has a **Generate** menu next to Import.

It supports:

- **Generate 1 Test Image**
- **Generate 27-Image Set**
- **Soldier** mode
- **Civilian** mode

The 27-image set is based on the original Luke March 20 prompt structure and pose coverage:

- front-view set
- close-up set
- full-body front / left / right / back
- 45-degree left / right
- strict left / right profiles

The prompt wording was adapted from the original Luke batch into a more **character-agnostic** Amira-world prompt so it can work for characters like **Amira** as well as Luke.

Defaults for this inspiration-generation flow:

- aspect ratio: **21:9**
- image size: **4K**
- references: main inspiration reference first, then inspiration images
- every request still goes through the Gemini/Nano Banana **preflight sheet** before sending

## Stored Prompt Metadata For Generated Inspiration Images

Generated inspiration images now save prompt metadata in a sidecar JSON next to the image.

That enables:

- prompt viewing later from the gallery
- carrying the exact prompt/model/size/aspect information forward

This is especially important now that the inspiration pane can generate full prompt-driven reference sets.

## Install / Signing

The updated app was rebuilt and reinstalled to:

- `/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app`

Current installed designated requirement remains stable:

- `identifier "com.amira.writer"`

Install timestamp after this round:

- `2026-03-30 00:13:19 PDT`
