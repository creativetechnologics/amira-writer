# Amira3DEngine

Isolated Swift package scaffold for Amira's future native 3D engine.

## Current package slices

- `Core/` — stable IDs, JSON values, math/transform types
- `Commands/` — deterministic command DSL inputs
- `Plans/` — scene plan container
- `Preview/` — review/apply preview and validation models
- `Registries/` — world, asset, camera, style, character, motion, light, atmosphere, and viseme contracts
- `IO/` — JSON registry loading
- `Compiler/` — plan-to-preview compilation
- `Runtime/` — placeholder state graphs and runtime shell

## Current goal

Keep all 3D logic isolated and compile-tested without touching the existing 2D Animate runtime or app integration points yet.
