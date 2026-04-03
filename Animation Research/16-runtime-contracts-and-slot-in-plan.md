# 16 — Runtime Contracts and Slot-In Plan

Date: 2026-03-31

## Purpose
Translate the research corpus into a future integration contract that can be dropped into the real app later with minimal ambiguity.

## Module split

### 1) Package Builder
Owns approved package manifests and asset-family records.

Inputs:
- master sheets
- head sheets
- costume sheets
- accessory sheets
- approved generated variants
- human annotations / AI review output

Outputs:
- vNext package JSON
- normalized asset folders
- readiness score
- package QA record

### 2) Body Motion Engine
Owns sparse keyframe playback and primitive composition.

Inputs:
- motion plans
- package motion primitives
- scene timing
- camera plan

Outputs:
- resolved transforms
- sprite/part selections
- overlay hooks

### 3) Mouth Engine
Owns speech/singing viseme and mouth-shape sequencing.

Inputs:
- lyrics / dialogue / phoneme timing
- mouth profile
- head angle / facing state
- mouth anchor placement

Outputs:
- mouth layer swaps
- openness values
- timing overrides
- mouth QA diagnostics

### 4) Overlay Engine
Owns blink, gaze, breathing, cloth/hair secondary motion, prop toggles.

### 5) Shot Router
Chooses among:
- internal runtime only
- hybrid internal + AI edit/fill
- AI video fallback

## Contract objects that should exist before app integration

### Character package manifest
Already prototyped in `prototypes/character_package_vnext_schema.json`.

### Motion plan
Already prototyped in `prototypes/motion_plan_schema.json`.

### Mouth profile
Already prototyped in `prototypes/mouth_profile_schema.json`.

### Asset review result
Already prototyped in `tools/asset_review_schema.json`.

## Minimal slot-in plan

### Phase 1 — Research sandbox validation
- generate a starter package skeleton
- validate it with readiness tooling
- validate a motion plan against the schema
- validate a mouth profile against the schema
- review sample generated assets against the QA schema

### Phase 2 — Non-destructive app bridge
- load vNext package JSON in parallel with current package format
- do not replace current package runtime yet
- build adapter objects only

### Phase 3 — Runtime pilot
- support a single internal shot type:
  - one character
  - torso-up dialogue
  - neutral costume
  - front / quarter-turn only
- add mouth engine overlay

### Phase 4 — Expansion
- locomotion
- hand/prop swaps
- additional costumes
- scene-level shot routing

## Recommended integration interfaces

### PackageProvider
Resolves package manifests, costume packs, mouth profiles, and asset families.

### MotionPlannerAdapter
Accepts LLM-authored sparse plans and normalizes them into runtime-safe plans.

### MouthRuntimeAdapter
Accepts phoneme or lyric timing plus facing info and emits mouth layer instructions.

### AssetQAService
Runs AI review, records issues, and suggests edit vs regenerate.

## Principle
Do not integrate raw generation prompts directly into the runtime.
Always pass through:
1. approved package record
2. readiness gate
3. shot plan contract
4. QA metadata
