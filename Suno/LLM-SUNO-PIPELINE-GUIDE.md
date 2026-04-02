# Suno Cover Generation Pipeline — LLM Agent Guide

**Last updated:** 2026-03-25
**Repo:** `/Volumes/Storage VIII/Programming/Amira Writer/Suno/`
**Project:** Amira — A Modern Opera

This file is now a short orientation guide.
For the full live workflow, operational status, and exact procedures, follow `HANDOFF.md`.
If anything conflicts, `HANDOFF.md` wins.

---

## Read In This Order

1. `README.md`
2. `HANDOFF.md`
3. `CANONICAL-SUNO-COVER-PROMPTS.md`
4. `SUNO-EXPORT-MASTER.md`
5. `archive/` only if you need historical debugging context

---

## What The Pipeline Does

1. Export a fresh silent WAV from the Amira score project
2. Upload that WAV to the local Suno MCP server on `127.0.0.1:3001`
3. Create a Suno cover with the canonical prompt/sliders
4. Poll until both generated songs complete
5. Download both WAV outputs into the song's preview folder

The three components are:

```text
Score headless export -> Suno MCP server -> Suno.com generation/download
```

---

## Hard Rules

- Project root: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera`
- Song files live under: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Songs`
- All upload/download WAVs live under: `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno`
- Browser automation is always headless; never open a visible browser window
- Always make a fresh `v###-Upload.wav` for each new batch
- Use the exact canonical prompt text from `CANONICAL-SUNO-COVER-PROMPTS.md`
- Treat export exit code `10` as a warning, not a hard failure

---

## Current Canonical Files

| File | Role |
|---|---|
| `HANDOFF.md` | Full workflow, current status, and troubleshooting |
| `CANONICAL-SUNO-COVER-PROMPTS.md` | Exact prompt and slider defaults |
| `SUNO-EXPORT-MASTER.md` | Export-specific rules |
| `run_amira_midi_batch.py` | Main resumable instrumental batch runner |
| `test_cover_variants.py` | Reusable validation/template run |
| `test_no_piano.py` | Current no-piano experiment |

Historical incident notes and one-off scripts were moved under `archive/` so they do not compete with the current instructions.

---

## Active Operational Notes

- The MCP server is expected at `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/`
- Health check: `http://127.0.0.1:3001/health`
- Status endpoint: `http://127.0.0.1:3001/api/v1/status`
- Progress stream: `http://127.0.0.1:3001/api/v1/progress`
- Current progress snapshot: `http://127.0.0.1:3001/api/v1/progress/current`

The main tools used by the scripts are:

- `suno_open_browser`
- `suno_create_cover`
- `suno_get_cover_status`
- `suno_download_cover`
- `suno_evaluate_js`

---

## Export Behavior To Remember

- Use `Scripts/export-headless-wav.sh`
- Export path uses the vendored `Packages/Score` binary inside the Opera repo
- SF2 and Audio Unit export paths are both silent as of 2026-03-25
- `133`, `134`, `139`, and other `128+` signal exits are retryable
- `10` means the WAV may be silent but the export completed; log it and decide whether to proceed

---

## Prompt Behavior To Remember

- Default orchestral instrumental prompt, negative prompt, and sliders live in `CANONICAL-SUNO-COVER-PROMPTS.md`
- Vocal covers must include real lyrics
- The current no-piano experiment adds `-piano, -keyboard, -keys` in `test_no_piano.py`

---

## Known Naming Quirk

The REASON score file on disk is currently `Songs/1.32.1 - REASON.ows`, but existing Suno output/version history still uses the legacy base title `1.23.0 REASON`.
Current scripts preserve that legacy Suno title while exporting the real on-disk song file.

---

## Common Pitfalls

1. Do not use the retired standalone `Novotro Score` repo as the export source
2. Do not use `~/Desktop/Novotro Previews`; all outputs belong under the Amira project's `Suno/` folder
3. Do not shorten prompts like `orchestra, instrumental`; expand them fully
4. Do not assume CAPTCHA should open a visible browser; this workflow stays headless
5. Do not reuse upload WAVs from an older batch
