# Places Worldbuilding Fill Handoff — 2026-04-21

This brief is for the next agent. Your job is to take structured markdown place descriptions from the user and populate the new Place worldbuilding brief fields in the Amira Writer data store.

## Scope

- Work only on Place (`BackgroundPlate`) records.
- Match each source entry to an existing Place by `displayName` / visible place name.
- Match case-insensitively and ignore punctuation.
- Only apply a match when you are confident.
- If more than one existing Place could match, stop and ask Gary which one to use.
- If a source entry does not exist in the app yet, create a new Place with that display name and the source category, then fill the fields below.

## Persistence / write path

Do **not** hard-code a persistence file path unless you verified it in the current repo state.

Before editing data, locate the persistence path by searching the codebase for where `places` is written. Start with searches like:

- `rg -n "places.json|writePlaces|save\(writePlaces" .`
- inspect the store save method and any place-specific persistence helpers

If you are running the app/UI, prefer using the dedicated store setters.
If you are running headless, you may edit the persisted places JSON directly **only after** confirming you found the live persistence file from the code.

## Field mapping

Use this exact mapping when copying from the source markdown:

| Source markdown field | Destination |
| --- | --- |
| **Scenes:** | Already tracked via `sceneUsage` / scene refs — **do not overwrite**. Verify the listed scenes match the existing scene refs and report any discrepancies. |
| **Category:** | `locationCategory` (map `Exterior`, `Interior`, `Vehicle` exactly) |
| **Side of River:** | `sideOfRiver` |
| **Time of Day:** | `timeOfDay` |
| **Day:** | `dayLabel` |
| **Position in the valley:** | `positionInValley` |
| `#### 1. Geographic Position` | `geographicPosition` |
| `#### 2. Physical Description` | `physicalDescription` |
| `#### 3. Sensory World` | `sensoryWorld` |
| `#### 4. Cultural & Historical Context` | `culturalHistoricalContext` |
| `#### 5. Inhabitants & Activity` | `inhabitantsActivity` |
| `#### 6. Key Props & Set Dressing` | `keyPropsSetDressing` (preserve bullet dashes as-is) |
| `#### 7. Dramatic Function` | `dramaticFunction` |
| `#### 8. Visual Continuity Anchors` | `visualContinuityAnchors` |
| `#### 9. Visual Palette & Lighting` | `visualPaletteLighting` |
| `#### 10. Camera & Framing Notes` | `cameraFramingNotes` |

## Canonical input format

Use the following as the canonical source format. The real source documents should follow this structure.

```markdown
### 1. Mountain Valley / The Ridge - Dawn (day 1)

**Scenes:** `1.01.0 - Overture`
**Category:** Exterior
**Side of River:** Ridge (base) side
**Time of Day:** Dawn
**Day:** Day 1
**Position in the valley:** A wide establishing view of the entire highland valley from the south-bank ridge, with the north-bank village below across the river, the glacier-fed mountains to the east, and the lower valley opening west.

#### 1. Geographic Position
The view sits high on the south-bank ridge above the river, looking down the valley's east-west axis...
(remaining sections 2–10 follow the same pattern — see the user's source doc for full text)
```

## Extraction rules

- Strip the `###` and `####` headers themselves, but keep the paragraph text under each section verbatim.
- Do **not** summarize.
- Do **not** rewrite.
- Do **not** re-flow line breaks unless the destination format absolutely requires it.
- Preserve em dashes and smart quotes.
- Preserve bullet dashes exactly as written, especially in `#### 6. Key Props & Set Dressing`.

## Idempotency / overwrite safety

- If any destination field already contains a non-empty value, do **not** silently replace it.
- Diff the existing value against the new source value and ask Gary before overwriting.
- This applies per field, not just per Place.
- If all mapped destination fields are already identical, report that the import is a no-op and do not rewrite the record.

## Scene verification rule

- `Scenes` from the source markdown are informational for validation only in this pass.
- Compare them against the existing `sceneUsage` / scene refs already stored on the Place.
- Report mismatches, missing scenes, or extra scenes.
- Do **not** change `sceneUsage` during this fill task unless Gary explicitly requests a separate scene-fix pass.

## Recommended workflow

1. Parse one source place block at a time.
2. Normalize the source place title and compare against existing Place names.
3. Resolve the target record or ask Gary if ambiguous.
4. Verify scene refs and note any discrepancies.
5. For each mapped field:
   - if destination is empty, populate it
   - if destination is non-empty and different, show a diff and ask before overwriting
6. Save/persist.
7. Re-open or re-read the saved record and verify the values actually stuck.
8. Report exactly which fields were filled, skipped, or blocked.

## Implementation note

If using UI/store methods, prefer the dedicated place update setters for the new worldbuilding fields.
If operating headless, edit the live persisted places JSON only after you confirm the real save file location from the code.
