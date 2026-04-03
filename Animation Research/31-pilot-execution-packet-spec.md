# 31 — Pilot Execution Packet Spec

Date: 2026-03-31

## Purpose
Define the exact bundle that should be assembled before the first real app pilot begins.

## Packet contents
A pilot execution packet should contain only approved or explicitly test-tagged artifacts.

### Required documents
- pilot shot definition
- package manifest
- mouth profile(s)
- motion plan
- asset review records
- promotion records
- readiness record
- routing decision record

### Required media references
- approved master sheet
- approved head turnaround sheet
- approved default costume body sheet
- approved accessory/detail sheet if the shot needs props

## Packet directory structure
- `packet.json` — top-level manifest for the packet
- `character-package.json`
- `motion-plan.json`
- `mouth-profiles/`
- `reviews/`
- `promotion-records/`
- `readiness.json`
- `routing.json`
- `refs/`

## Top-level packet fields
- packetId
- characterId
- shotId
- costumePackId
- routingMode
- readinessStatus
- requiredFiles
- notes

## Packet validity rules
A packet is valid only if:
- all referenced files exist
- readiness status is at least dialogue-ready
- routing mode is present
- motion plan and package manifest target the same character
- required mouth profiles exist for the shot angle families

## Why this matters
The pilot packet is the bridge from pure research to controlled implementation.
It keeps the future pilot reproducible and minimizes ambiguity during handoff.
