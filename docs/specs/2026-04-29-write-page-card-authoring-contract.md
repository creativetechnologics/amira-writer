# Write Page Card Authoring Contract

This is the current contract for agents and LLM tools that convert scratchpad prose into the Write page timeline. Do not use the old side-lane script-card system as the authoring target.

## Source Of Truth

- The Write page is a structured card timeline backed by the active `.ows` lyrics text.
- The user should see cards, not raw camera/action bracket syntax.
- Raw bracket markup remains a compatibility/export layer that the app silently rewrites when cards change.
- `Metadata/script-cards.json` is legacy/cache material and must not be treated as the source of truth for new Write-page shot cards.

## Timeline Sides

- Left of the timeline is story material:
  - lyric cards
  - action cards that describe story/action visible to the audience
- Right of the timeline is visual translation:
  - shot cards
  - camera/framing/movement/focus/intent
  - direction and notes needed to turn the story into an image

## Card Mapping Rules

- Lyric cards contain one stanza or short lyric beat.
  - Store the singer in the card speaker field.
  - Do not leave `CHARACTER:` speaker labels in visible lyric text when a lyric card can carry the speaker.
- Action cards contain story/action prose only.
  - Do not show square brackets in the card body.
  - If the backend needs bracket syntax, write it through the structured action-card projection.
- Shot cards start shots.
  - A shot continues until the next shot card starts.
  - Direction belongs inside the shot card Direction field.
  - Notes belong inside the shot card Notes field.
  - Camera, framing, movement, focus, intent, timing, character, prop, and location values should be written into the structured shot-card fields.
  - Time and spatial context should use `time_of_day` and `interior_exterior` (`interior`, `exterior`, `interior_to_exterior`, `exterior_to_interior`) so prompt generation does not have to infer this only from the location name.
  - Atmosphere and optics should use `weather_atmosphere`, `light_source`, `lens`, `camera_angle`, and `depth_of_field` when they matter for first-pass image prompting. Keep show-wide color palette direction outside the shot card unless a shot intentionally breaks the look.
  - Shot-specific continuity should use `continuity_notes` for practical details such as wardrobe state, prop hand, dust/blood level, eyeline, or blocking that must survive across generated frames.
  - Character blocking inside the frame should use the shot card's `character_left`, `character_middle`, and `character_right` fields. Treat these as the source of truth for which character or characters occupy the left, middle, and right portions of the image.
  - Character facing should use `character_left_facing`, `character_middle_facing`, and `character_right_facing` with values such as `towards_camera`, `away_from_camera`, `left`, `right`, `three_quarter_left`, or `three_quarter_right`.

## Scratchpad Conversion Guidance

When converting scratchpad notes into the Write page:

- Prefer adding or editing cards through `StructuredScriptDocumentProjector` APIs.
- Do not paste raw `[camera: ...]`, `[action: ...]`, `[object: ...]`, or old direction markup into the visible lyric surface.
- Preserve lyric wording unless the user explicitly asks to rewrite lyrics.
- Put visual-only notes on the right-side shot card, not in the left-side action column.
- If a note describes what the audience sees as story action, make it an action card.
- If a note describes how the camera sees it, make or update a shot card.

## Current Structured APIs

- Parse/export:
  - `StructuredScriptDocumentProjector.parse(_:hideLyricSpeakerCues:)`
  - `StructuredScriptDocumentProjector.export(_:)`
- Editing existing cards:
  - `updatingShotCard`
  - `updatingLyricSpeaker`
  - `updatingLyricBlockText`
  - `updatingHiddenMarkup`
- Moving timeline anchors:
  - `movingShotStart`
  - `movingShotEnd`
  - `movingLyricBlock`
- Creating cards:
  - `addingShot`
  - `addingLyricBlock`
  - `addingAction`

## Timing Direction

- Bars are temporary legacy timing hints.
- Future timing should migrate toward seconds/timecode derived from the score/mix timeline.
- Until the timecode model lands, do not invent irreversible timing schema. Keep timing edits compatible with the existing card fields.
