# 73 — Duet Lighting Pilot Packets

Date: 2026-03-31

## Purpose
Define lighting-aware duet pilot packets for scenes where Luke and Amira share the same location and must read as part of one light world while preserving their different visual priorities.

## Core rule
A duet lighting packet must not treat the two characters as separately lit shots stitched together.

Instead it should contain:
- one shared location lighting context
- one shared active lighting profile
- one shared routing expectation
- two character-specific read priorities
- two character-specific protection flags if needed

## Required duet packet fields
- `packetId`
- `shotId`
- `locationId`
- `lightingProfile`
- `routingMode`
- `characters`
- `sharedLightWorldNotes`
- `duetReadBalance`
- `requiredFiles`

## Character entry fields
- `characterId`
- `costumePackId`
- `readPriority`
- `lightingRisks`
- `protectionFlags`
- `mouthAngles`

## Top five duet packet targets
- district-clinic-exterior
- rooftop-sunset
- village-street-night
- clinic-interior-fluorescent
- family-courtyard

## Practical goal
Each duet packet should make it obvious how one unified location light can serve both characters without flattening their differences.
