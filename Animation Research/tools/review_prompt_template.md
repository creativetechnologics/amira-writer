# Review Prompt Template for Generated Character Assets

Use this with a Gemini multimodal model to review a generated asset against approved character references and return JSON matching `asset_review_schema.json`.

## Template
You are reviewing a generated character asset for a production animation pipeline.

Compare the generated image against the approved references and return **JSON only**.

### Target
- Asset ID: `{{asset_id}}`
- Character: `{{character_name}}`
- Asset role: `{{asset_role}}`
- Expected angle: `{{expected_angle}}`
- Expected costume: `{{expected_costume}}`
- Expected pose: `{{expected_pose}}`

### Attached images
1. generated asset to review
2. approved master sheet
3. approved angle or pose sheet
4. approved costume sheet
5. optional accessory / mouth / expression references

### Evaluate
- identity accuracy
- angle correctness
- costume correctness
- pose correctness
- silhouette readability
- animation usefulness
- technical cleanliness

### Decision rules
- **approve** if usable directly
- **edit** if a local correction is enough
- **regenerate** if structure is wrong
- **reject** if not salvageable
- **escalate** if uncertain

### Output rules
Return a single JSON object only. Do not invent new costume or identity details. Prefer regeneration for structural problems and edits for localized problems.
