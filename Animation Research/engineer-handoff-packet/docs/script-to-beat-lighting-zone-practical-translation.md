# 84 — Script To Beat-Level Lighting Zone/Practical Translation

Date: 2026-03-31

## Purpose
Extend script-to-lighting translation beyond shot-wide profile selection so the planner can decide which zones and practical channels matter on each beat of a shot.

## Core rule
The shared light world stays fixed for the shot.
Beat-level translation only changes emphasis within the existing location plan:
- which zones are emphasized
- which practicals become active or subordinate
- which protection channels rise for Luke or Amira

## Input requirements
A beat-level lighting cue payload should include:
- `shotId`
- `locationId`
- `lightingProfile`
- `beats[]`

Each beat should declare:
- `beatId`
- `description`
- `focusCharacter`
- `cameraBias`
- `zoneFocus`
- `practicalCue`
- `performanceMode`

## Output requirements
The translated beat plan should emit:
- `activeZoneChannels`
- `activePracticalChannels`
- `activeProtectionChannels`
- `mouthOverlayBias`
- `continuityNotes`

## Translation rule
A beat should only activate channels already allowed by the location plan. It may emphasize or de-emphasize those lanes, but it should not invent new channels.
