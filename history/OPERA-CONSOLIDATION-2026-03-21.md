# Opera Consolidation

## Goal

Make `Novotro Opera` self-contained in one workspace so another LLM can work from a single folder instead of tracing code across multiple sibling repos.

## What Was Consolidated

- Root app shell copied from `Novotro Write`
- Shared project infrastructure copied from `NovotroProjectKit`
- Score workspace copied from `Novotro Score`
- Animate workspace copied from `Novotro Animate`

## New Folder Layout

- `Sources/Opera`
- `Sources/NovotroWrite`
- `Packages/NovotroProjectKit`
- `Packages/NovotroScore`
- `Packages/NovotroAnimate`
- `history`

## Package Wiring Changes

- Root `Package.swift` now depends on:
  - `./Packages/NovotroProjectKit`
  - `./Packages/NovotroScore`
  - `./Packages/NovotroAnimate`
- Root executable target still builds `Opera`
- Vendored package manifests keep their own local structure and remain editable in place

## Intentional Non-Moves

- Legacy source repos were left on disk to avoid destructive reorganization during a live handoff.
- This new folder is the intended canonical workspace going forward.
- Historical exports, crash artifacts, and unrelated sidecar tooling were not pulled into this folder unless they were part of the actual Opera app codepath.
