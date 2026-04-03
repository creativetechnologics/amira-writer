# 83 — Location Lighting Zone/Practical Diff Reporting

Date: 2026-03-31

## Purpose
Define how zone-level and practical-level changes inside location lighting-plan JSON files are compared and reported.

## Block regressions
- a required location plan disappears from the index
- a location loses `zoneChannelAssignments`
- a location loses `practicalChannelAssignments` when practicals still exist
- a zone listed in `zoneMetadata.zones` no longer has a channel assignment
- a practical listed in `practicalMetadata.practicals` no longer has a channel assignment

## Warn changes
- a zone keeps an assignment but changes channels
- a practical keeps an assignment but changes channels
- `characterDepthZone` changes
- `backgroundGradeNotes` change

## Output bundle
The handoff packet should include:
- one passing zone/practical diff bundle
- one regressed zone/practical diff bundle
- machine-readable summary JSON for the report
