# Suno Generation Handoff

Date: 2026-03-23
Workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`

For the current canonical headless export path after the `Novotro Opera` consolidation, read:

- `/Volumes/Storage VIII/Programming/Novotro Opera/Suno/SUNO-EXPORT-MASTER.md`

This handoff remains useful historical context, but the master file above is now the source of truth for export invocation.

This handoff records the working export + Suno cover-generation process that finally stabilized the BBC Audio Unit renders, the background WAV export flow, and the cover submission rules for Prologue and related tests.

## Canonical References

- [Suno Export Master](/Volumes/Storage%20VIII/Programming/Novotro%20Opera/Suno/SUNO-EXPORT-MASTER.md)
- [Novotro Score: WAV-EXPORT-GUARDRAILS.md](/Volumes/Storage%20VIII/Programming/Novotro%20Score/docs/superpowers/WAV-EXPORT-GUARDRAILS.md)
- [Opera export-headless-wav.sh](/Volumes/Storage%20VIII/Programming/Novotro%20Opera/Scripts/export-headless-wav.sh)
- [Suno MCP handoff](/Volumes/Storage%20VIII/Users/gary/Library/Application%20Support/Novotro%20Score/suno-mcp/Codex%20Handoff%20Suno%20MCP.md)
- Current project path: `/Volumes/Storage VIII/Users/gary/Documents/Novotro Project Server/Projects/Amira.owp`
- Desktop preview folder: `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews`

## The Working Export Path

1. Use the full `.owp` package path for BBC-based exports.
2. Use the headless exporter when the GUI should not remain open.
3. Prefer the live playback-engine capture route for BBC / Audio Unit renders.
4. Keep the engine main mix alive across the playback engine's pre-play reset.
5. Write WAV data from a serial writer queue, not directly from the audio callback.
6. Finalize the WAV only after queued writes have drained.
7. For `.owp` exports, hydrate deferred playback from the project database before rendering.

Example:

```bash
Scripts/export-headless-wav.sh \
  --project "/Volumes/Storage VIII/Users/gary/Documents/Novotro Project Server/Projects/Amira.owp" \
  --song-path "Songs/1.02.0 - PROLOGUE - ARRIVAL - WITNESS.ows" \
  --output "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/Prologue version 019.wav"
```

## What Made The Clean WAVs Work

- `Prologue version 016.wav` became the clean reference export.
- `Prologue version 019.wav` reused the same good capture path after later level tweaks.
- The old clicky / choppy artifacts came from render/write behavior, not from Suno itself.
- If a BBC render turns into generic tones, verify that Core Audio can actually see and validate the BBC Symphony AU on that machine before exporting again.
- If `coreaudiod` burns CPU, check Bluetooth / AirPods first. Killing `coreaudiod` just causes launchd to relaunch it.

## Suno Cover Rules

### Preferred family moving forward

Use the orchestral family by default unless Gary explicitly asks for chamber tests or instrumental-only experiments.

Authoritative source:

- `/Volumes/Storage VIII/Programming/Novotro Opera/Suno/CANONICAL-SUNO-COVER-PROMPTS.md`

If there is ever a wording dispute, that file wins.

### `chamber cover`

Use this family exactly:

```text
chamber music, adagio for strings, lyrical woodwinds, <voice_mode>, same tempo, same structure, restrained dynamics
```

- Negative prompt: `-drums, -percussion, -cymbals, -snare, -kick`
- Sliders: `0 / 30 / 95`

### `orchestral cover`

Use this family exactly:

```text
orchestra, classical voice, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies
```

- Negative prompt: `-drums, -percussion, -cymbals, -snare, -kick`
- Sliders: `0 / 30 / 95`

### Voice mode rule

- Use `classical voice` for vocal covers.
- Use `instrumental` for instrumental-only tests.
- `chamber cover` and `orchestral cover` are style families, not fixed voice decisions.
- Do not hardwire `instrumental` into chamber unless the requested output is actually instrumental.

### Lyrics and gender

- For any vocal cover, always pass the real lyrics explicitly.
- Never leave the lyrics field blank on vocal covers.
- If lyrics are omitted, Suno may invent replacement text.
- Use manual vocal gender defaults until Novotro Score exposes metadata directly.
- For Prologue, Johnny is the singer, so use `vocal_gender=male`.

Character defaults:

- `Johnny` = `male`
- `Luke` = `male`
- `Mark` = `male`
- `Matt` = `male`
- `Amira` = `female`
- `Yasmin` = `female`

### File naming

Use natural, unsuspicious versioning:

- `<Track Name> version 001`
- `<Track Name> version 002`
- `<Track Name> version 003`

Keep three-digit version increments going forward unless Gary changes the rule.

## Suno MCP Notes That Matter

- `upload_audio()` now waits for a real post-save success condition instead of trusting the trim modal to disappear instantly.
- `create_cover(song_id=...)` should use the source-song page path: More menu -> Remix/Edit -> Cover.
- For uploaded source songs, do not create a second upload just because the first confirmation was slow.
- For vocal covers, `lyrics=...` must be populated or Suno can generate substitute lyrics.
- If Suno shows a CAPTCHA, solve it in a headed browser session and retry.
- Do not split the track into multiple source uploads when one source song is meant to feed both covers.

## Suno MCP create_cover Issue

`suno_create_cover()` fails with "Audio Influence slider not present after Cover mode selection" even when all 3 sliders ARE visible on screen. The tool's slider detection counts 2 instead of 3. Workaround: use manual UI navigation (upload → Keep Both → Cover → Continue → scroll → fill fields → set sliders individually with `suno_set_slider`).

## Failure Modes We Already Hit

- **Generic tones / sine-wave-ish output**: usually means the BBC Audio Unit was not discoverable or the export fell back to the wrong render path.
- **Clicky / choppy WAVs**: came from the old render/write behavior, especially blocking disk I/O on the audio thread.
- **False upload failure**: the upload had actually completed, but the trim modal was still visible.
- **Wrong lyrics in Suno**: vocal cover submitted without explicit lyrics.
- **Wrong voice gender**: the manual gender selection did not match the character.
- **CPU spike in `coreaudiod`**: linked to Bluetooth / AirPods churn, not a leftover Novotro process.

## Recovery Checklist

1. Export the WAV cleanly first.
2. Inspect the WAV in `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews`.
3. Upload one source song only.
4. Wait for a real success signal before retrying anything.
5. Generate chamber and orchestral covers from the same source song.
6. For vocal covers, verify lyrics and gender before submission.
7. If live playback and export diverge, treat them as separate bugs.

## BBC AU Loading Failure (2026-03-23)

On Garys-Server (Storage VIII), headless BBC Audio Unit export started producing **completely silent WAV files**. Root cause:

1. All 27 BBC Audio Units failed to load during headless export:
   ```
   [Engine] AU load timeout/failed for violins-i: OSStatus error -3000
   ...(all 27 instruments)
   ```
2. `auval -a` on Storage VIII shows only Apple system AUs — BBC Symphony Orchestra AUs not visible in registry
3. Gary confirms AUs ARE installed — this exact scenario has happened before
4. Previous working export: `Overture version 031.wav` (March 19, 179.7 sec, verified audio)
5. New export `1.01.0 OVERTURE version 001.wav`: 66MB but all-zero PCM (silent)

**Recovery options:** Rebuild AU plugin cache, or run export on machine with confirmed BBC AU access. The AUs work in GUI mode.

## Short Version

If you only remember a few things, remember these:

- Use the `.owp` package path and the headless BBC export path.
- Keep the live playback-engine capture route.
- Do not block the audio thread.
- Always send real lyrics for vocal Suno covers.
- Use `classical voice` for vocals and `instrumental` only when that is explicitly the goal.
- Keep the Suno preset strings exact.

This handoff complements the canonical docs in Novotro Score. Do not freestyle the preset strings or the export flow unless Gary explicitly changes the rules.
