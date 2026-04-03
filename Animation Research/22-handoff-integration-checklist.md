# 22 — Handoff Integration Checklist for Amira Writer

Date: 2026-03-31

## Purpose
Provide a concrete handoff checklist for the future moment when research work begins moving into the real app.

## Rule zero
Do not replace the current system all at once.
Integrate behind adapters and feature flags.

## Pre-integration requirements
- approved vNext schemas frozen for one pilot cycle
- at least one hero package validated in the research sandbox
- at least one motion plan example validated end-to-end
- at least one mouth profile and lyric plan validated end-to-end
- AI QA review output validated against the JSON schema
- package readiness model exercised on real character plans

## First implementation targets
### A. Package provider adapter
Must be able to:
- load a vNext manifest
- expose master/head/body sheet ids
- expose costume pack defaults
- expose mouth profile defaults
- not disturb existing package loading

### B. Motion-plan adapter
Must be able to:
- parse a sparse plan
- validate shot routing mode
- attach character states to scene characters
- resolve a primitive list into safe runtime instructions

### C. Mouth overlay adapter
Must be able to:
- read a mouth profile
- accept speech/singing event timing
- emit mouth-layer swaps with anchor placement
- fail gracefully if a mouth profile is missing

### D. QA/review storage adapter
Must be able to:
- store per-asset review JSON
- attach edit/regenerate recommendations
- track approval history

## First-pilot success criteria
- one character
- one costume
- front + quarter-turn dialogue shot
- speech-only mouth overlay first
- internal-only shot routing
- zero destructive migration of existing data

## Migration safety
- all new persistence should be additive
- all new manifest fields should be versioned
- no current package file should be overwritten without backup
- feature flag the new runtime path

## Engineering handoff notes
When app work begins, start from:
- `16-runtime-contracts-and-slot-in-plan.md`
- `17-character-package-build-playbook.md`
- `21-adapter-layer-and-compatibility-plan.md`
- `prototypes/`
- `examples/`
- `tools/`
