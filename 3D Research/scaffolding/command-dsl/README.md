# 3D Command DSL Scaffold

Purpose: provide a deterministic command layer between LLM planning and the Amira-native 3D runtime.

## Principles

1. The LLM outputs **commands**, not arbitrary engine code
2. Commands are validated before apply
3. Commands resolve against stable IDs:
   - world IDs
   - asset IDs
   - character IDs
   - preset IDs
4. Commands remain human-reviewable

## Proposed shape

```text
command-dsl/
  README.md
  examples/
    amira-3d-plan.example.json
```

## First command groups

- world
- style
- camera
- asset
- character
- dialogue
- mouth

