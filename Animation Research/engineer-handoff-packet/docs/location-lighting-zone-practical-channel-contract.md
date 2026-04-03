# 82 — Location Lighting Zone And Practical Channel Contract

Date: 2026-03-31

## Purpose
Define the per-location zone and practical channel fields that every duet lighting-plan JSON must declare so the runtime can relight backgrounds and motivated practicals deterministically.

## Required fields
Every location-specific duet lighting plan should now include:
- `zoneChannelAssignments`
- `practicalChannelAssignments`

## Zone assignment rules
- every zone in `zoneMetadata.zones` must appear in `zoneChannelAssignments`
- each zone should map to one or more channels from the shared 8-lane contract
- `ch04_background_separation` and `ch06_atmosphere_grade` are the most common background-facing lanes

## Practical assignment rules
- every named practical in `practicalMetadata.practicals` must appear in `practicalChannelAssignments`
- practicals usually drive `ch05_practical_accent` plus at least one supporting fill/grade lane
- a location with no practicals may use an empty object

## Regression policy
Missing zone/practical assignments are BLOCK regressions because they break deterministic relight coverage for that location.
