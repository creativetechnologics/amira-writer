# Suno Pipeline

Start here if you are new to this folder.

## Canonical order

1. `HANDOFF.md` — the full current workflow and live operational rules
2. `CANONICAL-SUNO-COVER-PROMPTS.md` — exact prompt text and slider defaults
3. `SUNO-EXPORT-MASTER.md` — headless WAV export rules only
4. `LLM-SUNO-PIPELINE-GUIDE.md` — short agent-facing orientation and file map

## Active scripts

- `run_amira_midi_batch.py` — main resumable instrumental batch runner
- `test_cover_variants.py` — reusable validation/template script for prompt experiments
- `test_no_piano.py` — current no-piano negative-prompt experiment

## Hard rules

- Export from `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera`
- Save all uploads/downloads under `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno`
- Browser automation stays headless at all times
- Always generate a fresh `v###-Upload.wav` for each new batch
- Use the full canonical Suno prompts; do not shorten them

## Historical material

Older incident notes and one-off scripts live under `archive/`.
They are for debugging context only and should not be treated as current instructions.
