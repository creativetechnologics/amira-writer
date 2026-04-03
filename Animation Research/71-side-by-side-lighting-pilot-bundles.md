# 71 — Side-by-Side Lighting Pilot Bundles

Date: 2026-03-31

## Purpose
Define paired lighting pilot bundles for Luke and Amira across the five highest-priority hero locations.

## Goal
For each key location, there should be two pilot-ready bundle descriptions:
- one for Luke
- one for Amira

Each pair should share the same location lighting context while still showing:
- costume response differences
- face readability differences
- mouth visibility considerations
- silhouette behavior
- practical-light sensitivity

## Top five locations
- district-clinic-exterior
- rooftop-sunset
- village-street-night
- clinic-interior-fluorescent
- family-courtyard

## Bundle structure
Each side-by-side pair should include:
- `locationId`
- `lightingProfile`
- `characterId`
- `costumeId`
- `readNotes`
- `lightingRisks`
- `protectionFlags`
- `routingExpectation`

## Why side-by-side matters
The same lighting profile should not read identically on both characters.

Examples:
- Luke's medic costume may carry stronger fabric-value separation under sunset.
- Amira's scarf/hair framing may need more careful face protection at night.
- Fluorescent interiors may flatten Luke's uniform differently than Amira's civilian garments.

## Pilot rule
Every key location should have a paired Luke/Amira pilot bundle before the first lighting-heavy engineering pilot begins.
