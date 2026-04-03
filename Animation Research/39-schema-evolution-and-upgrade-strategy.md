# 39 — Schema Evolution and Upgrade Strategy

Date: 2026-03-31

## Purpose
Define how the future animation data contracts should evolve without breaking the app or corrupting character packages.

## Rule zero
Never do a destructive in-place schema jump without:
- version numbers
- upgrade functions
- backups
- validation after upgrade

## Recommended versioned artifacts
- character package manifest
- motion plan
- mouth profile
- asset review record
- pilot packet

## Upgrade pattern
1. detect schema version
2. load old payload into a tolerant decoder
3. normalize missing/default fields
4. emit upgraded payload in the latest canonical form
5. validate against the latest schema
6. preserve the original as backup or adjacent artifact

## Versioning rules
- additive fields are preferred
- removals should go through a deprecation cycle
- adapters should handle one previous version when possible
- upgrade tools should be explicit and testable

## Research recommendation
Before live integration, create:
- one upgrade example from v1 → v2 manifest
- one upgrade example from older mouth profile → newer mouth profile
- one compatibility report showing what changed

## Safety checklist
- backup exists
- source and upgraded payload both parse
- upgraded payload validates
- ids and file references remain stable
- no promoted references are dropped silently
