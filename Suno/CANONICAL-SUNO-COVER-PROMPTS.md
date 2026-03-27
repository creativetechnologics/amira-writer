# Canonical Suno Cover Prompts

This file is the source of truth for Suno cover prompt wording in this project.

If an agent is generating Suno covers for Amira, it must read this file first.
Do not invent a new prompt family. Do not shorten these prompts. Do not paraphrase them.

## Canonical families

### `chamber cover`

Use this family exactly:

```text
chamber music, adagio for strings, lyrical woodwinds, <voice_mode>, same tempo, same structure, restrained dynamics
```

### `orchestral cover`

Use this family exactly:

```text
orchestra, <voice_mode>, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies
```

## Voice mode rule

- Use `classical voice` for vocal covers.
- Use `instrumental` for instrumental-only covers.
- `chamber cover` and `orchestral cover` are style families, not fixed voice decisions.

## Canonical negative prompt

Use this exact negative prompt:

```text
-drums, -percussion, -cymbals, -snare, -kick
```

## Canonical sliders

Use these exact sliders unless Gary explicitly requests a different experiment:

```text
weirdness=0
style_influence=30
audio_influence=95
```

## Instrumental batch rule

For the current instrumental orchestral batch, the exact resolved prompt is:

```text
orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies
```

Use:

- lyrics: `[Instrumental]`
- negative prompt: `-drums, -percussion, -cymbals, -snare, -kick`
- sliders: `0 / 30 / 95`

## Hard rule for agents

If an agent sees shorthand such as:

- `orchestra`
- `orchestral`
- `orchestral cover`
- `orchestra, instrumental`
- `chamber`
- `chamber cover`

the agent must expand that shorthand to the exact canonical family in this file before submitting anything to Suno.

Submitting vague prompts such as `orchestra, instrumental` without expansion is a workflow bug.
