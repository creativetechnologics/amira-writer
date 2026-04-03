# 49 — Schema Upgrade Transform Sketches

Date: 2026-03-31

## Purpose
Sketch how simple manifest upgrades should work before real migration tooling exists.

## Example v1 → v2 package upgrade
### Inputs in v1
- schemaVersion
- packageId
- characterIdentity
- costumePacks
- motionPrimitives

### Fields added in v2
- mouthProfiles
- qa
- defaults

## Suggested transform
- preserve all original fields
- add empty or default mouth profile array
- add draft QA block if missing
- infer defaults from the first costume pack when possible
- record upgrade metadata separately if needed

## Why this is useful
A transform sketch keeps future migrations deliberate and testable rather than improvised.
