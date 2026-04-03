# 29 — First Pilot Bundle Definition

Date: 2026-03-31

## Purpose
Define the smallest production-meaningful pilot that should eventually leave the research sandbox first.

## Pilot goal
Prove that Amira Writer can drive one internally animated dialogue/singing-adjacent shot from:
- a curated character package
- a sparse motion plan
- a separate mouth profile
- deterministic QA and routing logic

## Recommended pilot
### Character
Luke Hart

### Costume
Medic desert / field costume

### Shot type
Torso-up dialogue or restrained singing line

### Angle coverage
- front
- quarter-left
- quarter-right

### Camera
Static or lightly eased camera

### Routing
Internal only

## Required asset bundle
### Identity / sheet assets
- 1 master sheet
- 1 head turnaround sheet
- 1 body sheet for medic costume

### Body runtime assets
- neutral idle
- concerned idle
- small turn front→quarter-left
- small turn front→quarter-right
- one reach gesture
- one react gesture

### Mouth runtime assets
Per needed angle family:
- rest
- mbp
- ee_tight
- eh_mid
- aa_wide
- oh_round
- oo_pucker
- belt or strain optional for the pilot

### QA assets
- review history for each candidate
- approved reference set
- promoted reference subset

## Required contracts
- package manifest
- motion plan
- mouth profile
- asset review JSON

## Pilot success criteria
- correct identity throughout the shot
- correct costume throughout the shot
- sparse motion plan plays predictably
- mouth overlay tracks correctly across angle changes
- result is editable / retakable

## Why this pilot matters
If this works, the architecture is real.
If it fails, it will fail cheaply and reveal which contract is still too weak.
