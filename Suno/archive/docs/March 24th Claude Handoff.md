# March 24th Claude Handoff

## Purpose

This document is the authoritative handoff for continuing the March 24, 2026 Amira MIDI-to-Suno batch.

The goal is to continue the existing batch for all remaining MIDI-backed Amira songs without re-learning the workflow, without guessing prompts, and without re-introducing bugs that have already been fixed.

This handoff assumes:

- The Novotro Opera repo is at:
  `/Volumes/Storage VIII/Programming/Novotro Opera`
- The Amira project is at:
  `/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera`
- Suno MCP is at:
  `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp`
- Preview outputs go to:
  `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews`

## Current Pause State

The batch was intentionally paused by user request.

At pause time:

- The batch runner was interrupted manually with `Ctrl-C`
- No song was actively being exported or submitted at the moment of pause
- The last fully completed song was:
  `2.10.0 - JOHNNY'S THEME.ows`
- The next queued song is:
  `2.20.0 - THE SHOOTING.ows`
- The Suno MCP HTTP server is still running on:
  `http://127.0.0.1:3001`
- The browser is still open and currently on the generated Suno page for:
  `2.10.0 JOHNNY'S THEME v002`

Current MCP status at pause:

- `browser_open: true`
- `page_ready: true`
- `current_url: https://suno.com/song/ea62aba1-aedd-425c-a47f-d08110f04f36`
- `page_title: 2.10.0 JOHNNY'S THEME v002 by creativetechnologics | Suno`

## Canonical Batch Rules

These are not suggestions. They are the batch contract.

- Run one upload per song
- Run one Suno cover set per song only
- Each song produces exactly:
  - `v001-Upload.wav`
  - `v002-A.wav`
  - `v002-B.wav`
- This batch is instrumental only
- Do not generate vocals
- Do not shorten the Suno style prompt
- Do not improvise a new prompt
- Do not force the `Amira` workspace
- Use Suno's current/default workspace state only
- If a song is already completed in the JSONL log, do not redo it
- `2.07.0 - MARK IN THE WIRES.ows` is intentionally skipped and should remain skipped

## Canonical Suno Prompt

This is the exact style prompt for this batch:

```text
orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies
```

Companion fields:

- Lyrics:
  ```text
  [Instrumental]
  ```
- Negative prompt:
  ```text
  -drums, -percussion, -cymbals, -snare, -kick
  ```
- Sliders:
  - Weirdness: `0`
  - Style influence: `30`
  - Audio influence: `95`

Canonical prompt doc:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/CANONICAL-SUNO-COVER-PROMPTS.md](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/CANONICAL-SUNO-COVER-PROMPTS.md)

Related docs:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/SUNO-EXPORT-MASTER.md](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/SUNO-EXPORT-MASTER.md)
- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/HANDOFF-2026-03-23-SUNO-GENERATION.md](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/HANDOFF-2026-03-23-SUNO-GENERATION.md)
- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/HANDOFF-2026-03-24-SUNO-WAV-DOWNLOAD-GUARDRAILS.md](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/HANDOFF-2026-03-24-SUNO-WAV-DOWNLOAD-GUARDRAILS.md)

## Naming And Folder Rules

Each song gets its own folder under:

- `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/<Base Title>/`

Example:

- `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/2.10.0 JOHNNY'S THEME/`

Files inside follow this exact scheme:

- Upload:
  - `Base Title v001-Upload.wav`
- Cover A:
  - `Base Title v002-A.wav`
- Cover B:
  - `Base Title v002-B.wav`

Important:

- Use `v`, not `version`
- Suffix letters are uppercase: `A`, `B`
- Versioning resets per song
- The Suno song title should match the generated title, for example:
  - `2.10.0 JOHNNY'S THEME v002`
- The local WAV filenames should mirror that version title

Version tracking is backed by the MCP ledger at:

- [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/suno-song-ledger.sqlite3](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/suno-song-ledger.sqlite3)

## Batch Runner

The main resumable batch script is:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py)

The live progress log is:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/amira-midi-batch-progress-2026-03-24.jsonl](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/amira-midi-batch-progress-2026-03-24.jsonl)

This script is now the primary continuation path.

## How To Resume

### 1. Confirm the MCP server is up

Health endpoint:

```bash
rtk proxy curl -s http://127.0.0.1:3001/api/v1/status
```

If the server is not up, start it with:

```bash
rtk bash -lc 'cd "/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp" && export PYTHONPATH=src SUNO_HOST=127.0.0.1 SUNO_PORT=3001 && venv/bin/python -c "import time, logging, uvicorn; logging.basicConfig(level=logging.INFO); from suno_mcp.server import fastapi_app; fastapi_app.start_time = time.time(); uvicorn.run(fastapi_app, host=\"127.0.0.1\", port=3001)"'
```

### 2. Resume the batch

Run:

```bash
rtk python3 "/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py"
```

The runner will:

- read the JSONL log
- skip any song already marked `song_done`
- skip `2.07.0 - MARK IN THE WIRES.ows`
- continue at the next unfinished song

At pause time, the next unfinished song is:

- `2.20.0 - THE SHOOTING.ows`

## Completed Songs So Far

These songs are already done and should not be regenerated:

1. `1.01.0 - OVERTURE.ows`
2. `1.02.0 - PROLOGUE - ARRIVAL - WITNESS.ows`
3. `1.05.0 - SILVER.ows`
4. `1.08.0 - THE SHORTCUT.ows`
5. `1.14.0 - FIRST MEETING.ows`
6. `1.17.0 - BRASS LAMENT (Mass Casualty).ows`
7. `1.20.0 - GRACE.ows`
8. `1.23.0 - REASON.ows`
9. `1.25.0 - TIME OF WAR.ows`
10. `1.26.0 - HOW.ows`
11. `1.27.0 - SOMEWHERE IN MY HEART.ows`
12. `1.28.0 - A NEW LIFE.ows`
13. `1.32.0 - SEE IT THROUGH.ows`
14. `1.34.0 - THE RETURN.ows`
15. `1.44.0 - SOMETHING MORE (Act I Finale).ows`
16. `2.01.0 - ENTRACTE (Act II opening).ows`
17. `2.07.0 - MARK IN THE WIRES.ows`
18. `2.09.0 - THE CONFESSION.ows`
19. `2.10.0 - JOHNNY'S THEME.ows`

Important note:

- Item 17 is a skip, not a generated song
- So there are `18` actual generated song folders complete, plus `1` intentional skip

## Remaining Songs

These are still pending:

1. `2.20.0 - THE SHOOTING.ows`
2. `2.24.0 - ALONE.ows`
3. `2.26.0 - MARK'S LAMENT.ows`
4. `2.28.0 - STORIES.ows`
5. `2.29.0 - JOHNNY'S GOODBYE - FINALE.ows`
6. `8.01.0 - STREETLIGHTS.ows`
7. `8.02.0 - FAREWELL.ows`
8. `8.03.0 - LUKE AND AMIRA.ows`
9. `8.04.0 - NIGHTFALL.ows`

## MCP And Workflow Fixes Already Made

These fixes are already in place and should be preserved.

### Suno MCP fixes

Primary file:

- [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/basic/tools.py](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/basic/tools.py)

Other important files:

- [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/shared/form_helpers.py](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/shared/form_helpers.py)
- [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/server.py](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/server.py)
- [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/shared/song_versions.py](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/shared/song_versions.py)

Implemented behavior:

- Hidden hCaptcha scaffolding no longer falsely blocks cover creation
- Download auth is more robust and can obtain the proper token path
- WAV downloads save with the actual Suno song title, not a UUID fallback
- Downloads go into the correct per-song folder
- Cover download is guarded so it refuses to run against the wrong page type unless the cover is already confirmed by song ID / ledger
- URL detection no longer mistakes `cdn1.suno.ai/<id>.wav` for a song page
- Naming uses `v###-Upload`, `v###-A`, `v###-B`
- Per-song version state is tracked in the SQLite ledger
- Generic shorthand prompts are auto-expanded to the canonical orchestra preset
- The forced `Amira` workspace change was reverted; current behavior is to use Suno's normal/default workspace state

### Batch runner fixes

Primary file:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py)

Implemented behavior:

- Resume from JSONL state
- Discard stale `cover_ids`
- Re-check whether stored cover IDs are still live
- Retry MCP HTTP calls when the local server is briefly unavailable
- Skip `2.07.0 - MARK IN THE WIRES.ows`
- Retry intermittent export `SIGTRAP` failures up to 3 times before hard failure

### Headless export fixes

Files:

- [/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/export-headless-wav.sh](/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/export-headless-wav.sh)
- [/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/Sources/NovotroScore/NovotroScoreBootstrap.swift](/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/Sources/NovotroScore/NovotroScoreBootstrap.swift)

Implemented behavior:

- Export wrapper watches the WAV file and can stop a lingering headless exporter after a valid file is stable
- Headless bootstrap preloads playback more reliably from `.ows`
- If the selected version has no playback notes, fallback activation can choose a playable version
- If the active playback version is pathological, the bootstrap can switch to a sane fallback version

## Important Recovery Cases Already Encountered

### 1. `2.07.0 - MARK IN THE WIRES.ows`

User confirmed this song does not actually have music content worth processing.

Permanent action taken:

- The batch runner explicitly skips it
- It is logged as:
  - `song_skipped`
  - then `song_done`

Do not remove this skip unless the user explicitly reverses that instruction.

### 2. `1.28.0 - A NEW LIFE.ows`

This one had pathological active-version playback data.

What happened:

- The active version looked wrong for playback
- A fallback version with sane bounds and dense note data existed
- The headless bootstrap was hardened to choose that sane fallback

Result:

- Export succeeded
- The song was completed without a second upload

### 3. `2.10.0 - JOHNNY'S THEME.ows`

This song hit an intermittent export failure:

- return code `133`
- `Trace/BPT trap: 5`

Important finding:

- The song itself is valid
- Its active version has solid playback notes
- A direct export succeeded cleanly

Permanent mitigation:

- The batch runner now retries this intermittent export trap automatically

Manual recovery that was used:

- Direct export succeeded to:
  - `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/2.10.0 JOHNNY'S THEME/2.10.0 JOHNNY'S THEME v001-Upload.wav`
- A matching `export_ok` line was appended to the JSONL log
- The runner was relaunched and resumed from cover creation

## Exact Files Worth Inspecting First

If Claude needs to inspect before resuming, start here:

1. [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py)
2. [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/amira-midi-batch-progress-2026-03-24.jsonl](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/amira-midi-batch-progress-2026-03-24.jsonl)
3. [/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/export-headless-wav.sh](/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/export-headless-wav.sh)
4. [/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/Sources/NovotroScore/NovotroScoreBootstrap.swift](/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/Sources/NovotroScore/NovotroScoreBootstrap.swift)
5. [/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/basic/tools.py](/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/basic/tools.py)
6. [/Volumes/Storage VIII/Programming/Novotro Opera/Suno/CANONICAL-SUNO-COVER-PROMPTS.md](/Volumes/Storage VIII/Programming/Novotro Opera/Suno/CANONICAL-SUNO-COVER-PROMPTS.md)

## What Not To Do

- Do not force the `Amira` workspace
- Do not generate chamber prompts for this batch
- Do not invent shortened prompts like `orchestra, instrumental`
- Do not upload the same song twice if an upload already exists and the log state is recoverable
- Do not generate more than one cover set per song
- Do not rename files away from the `v###` format
- Do not delete the JSONL log
- Do not restart numbering on already-started songs
- Do not treat `MARK IN THE WIRES` as pending

## Resume Checklist For Claude

1. Confirm the MCP server responds on port `3001`
2. If not, start it with the exact command in this handoff
3. Confirm the browser is open and usable
4. Run the batch script:
   - `rtk python3 "/Volumes/Storage VIII/Programming/Novotro Opera/Suno/run_amira_midi_batch.py"`
5. Watch the JSONL log for:
   - `song_start`
   - `export_ok`
   - `cover_ids`
   - `download_ok`
   - `song_done`
6. If an export hits `rc 133 / Trace/BPT trap: 5`, the runner now retries automatically
7. If a song still fails after retries, diagnose the song specifically and patch the workflow rather than stopping the whole batch

## Current Bottom Line

At the moment of handoff:

- The batch is paused by user request
- `19` songs are marked done in the log
- `18` of those are actual generated/exported songs
- `1` is the intentional skip for `MARK IN THE WIRES`
- `9` songs remain
- The next song to process is:
  - `2.20.0 - THE SHOOTING.ows`

This document, the JSONL log, the batch runner, and the MCP server are enough for Claude Code to continue from here without guessing.
