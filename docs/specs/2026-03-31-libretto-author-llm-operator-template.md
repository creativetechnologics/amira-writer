# Libretto Author LLM Operator Template

Use this when you want to hand one specific scene to the libretto-writing LLM with concrete scene data.

Primary contract:
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-03-31-libretto-visual-direction-master-contract.md`

Companion prompt:
- `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-03-31-libretto-author-llm-prompt.md`

---

## Fillable operator template

```text
Use the master contract at `/Volumes/Storage VIII/Programming/Amira Writer/docs/specs/2026-03-31-libretto-visual-direction-master-contract.md` as binding.

Rewrite the libretto scene by scene so Animate can interpret it immediately.

Behave as both a director and cinematographer. Preserve the dramatic meaning, lyrics, and scene order. Do not paraphrase lyrics, do not merge or split scenes, and do not invent unsupported formatting.

## Scene packet
- Scene name: {{SCENE_NAME}}
- Song path: {{SONG_PATH}}
- Audio path: {{AUDIO_PATH}}
- Approved place/background: {{PLACE_BACKGROUND}}
- Cast names: {{CAST_NAMES}}
- Existing scene shots: {{EXISTING_SCENE_SHOTS}}
- Recurring object names: {{RECURRING_OBJECTS}}
- Timing notes: {{TIMING_NOTES}}
- Additional directing guidance: {{DIRECTING_GUIDANCE}}
- Operator notes: {{OPERATOR_NOTES}}

## Scene text
{{SCENE_TEXT}}

## Required output
- Return only the rewritten scene text unless explicitly asked for analysis.
- Use the canonical bracketed Animate DSL from the master contract.
- Keep critical visual logic inside bracket blocks.
- Use unique shot labels inside the scene.
- Keep all timing scene-local.
- Treat objects/props as first-class scene elements.
```

---

## Placeholder guidance

- `{{SCENE_NAME}}` — exact scene title
- `{{SONG_PATH}}` — relative song path if available
- `{{AUDIO_PATH}}` — scene-local mix/audio path if available
- `{{PLACE_BACKGROUND}}` — approved place/background name
- `{{CAST_NAMES}}` — comma-separated cast list for the scene
- `{{EXISTING_SCENE_SHOTS}}` — authored shots already present in Animate
- `{{RECURRING_OBJECTS}}` — approved/stable recurring object names
- `{{TIMING_NOTES}}` — musical phrase boundaries, bars, beats, or timing cautions
- `{{DIRECTING_GUIDANCE}}` — extra direction you want the LLM to consider
- `{{OPERATOR_NOTES}}` — anything else the operator needs to convey
- `{{SCENE_TEXT}}` — exact libretto scene text to rewrite
