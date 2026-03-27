# Suno WAV Download Guardrails and Version Ledger

Date: 2026-03-24

## Purpose

This document records the exact Suno MCP behavior that must be preserved for
future agents.

The main problems that had to be fixed were:

1. The MCP was creating fake local filenames like `version 006`, `version 007`,
   `version 008`, etc. even when Suno did not have songs with those names.
2. The automation could land on the wrong Suno song page and still attempt a
   WAV download.
3. The headless UI path `More -> Download -> WAV Audio` can still fail to expose
   the nested `WAV Audio` item in some sessions, so a safe fallback is required.
4. The naming convention needed to reset per song, use `v###` instead of
   `version`, and remember which generated `song_id` maps to `-A` / `-B`.

The current solution preserves a safe fallback while adding a hard guard against
wrong-page downloads.

---

## Canonical Rules

### Naming rules

- Upload titles in Suno should end with:
  - `<Song Title> vNNN-Upload`
- Generated cover titles in Suno should end with:
  - `<Song Title> vNNN`
- Downloaded WAV filenames should follow the same base song, with local
  variant suffixes:
  - `<Song Title> vNNN-Upload.wav`
  - `<Song Title> vNNN-A.wav`
  - `<Song Title> vNNN-B.wav`
- The MCP must not invent global version numbers.
- Versioning resets per song title.
- The ledger is the source of truth for:
  - the next version for each song
  - the `song_id -> version/variant` mapping
- If a version number is desired in the downloaded WAV filename, that version
  must be established in Suno before or during submission.

### Workspace rules

- Do not force workspace selection in this flow.
- Let Suno use its normal current/default workspace state unless Gary asks for
  a specific workspace again and it is revalidated live.

### Cover creation rule

- For local WAV uploads, prefer the uploaded source song row that appears in the
  current workspace pane and launch `Cover` from that song page.
- Treat the create-page upload modal as a fallback only. It is too fragile to be
  the primary cover-attachment path.

### Download rules

- `suno_download_cover(song_id=...)` is only for generated cover pages.
- Before any download is allowed, the page must prove that it is a generated
  cover page.
- Required visible markers:
  - a model tag like `v5` or `v6`
  - `Cover of` metadata
- If those markers are missing, `suno_download_cover()` must refuse to download.

### Operational rules

- Never assume the browser is on the correct page just because a song page URL
  loaded.
- Never run multiple `suno_download_cover()` requests concurrently against the
  same MCP browser session. The tool uses one shared Playwright page, so
  concurrent calls can interrupt each other.

---

## Code Changes

The key MCP files are:

- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/basic/tools.py`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/tools/shared/song_versions.py`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/server.py`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/Codex Handoff Suno MCP.md`

### `tools.py`

Current behavior:

- `_read_song_title()`
  - reads the visible Suno song title from the page
  - falls back to the browser title if needed
- `SongVersionLedger`
  - stores state in:
    - `~/Library/Application Support/Novotro Score/suno-mcp/suno-song-ledger.sqlite3`
  - tracks:
    - per-song next version numbers
    - `song_id -> version/variant` records
  - gives the MCP a durable memory so future downloads stay aligned with the
    same song title
- `_resolve_song_download_target()`
  - creates the song folder from the base title
  - resolves the filename from the ledger when possible
  - saves files as:
    - `... vNNN-Upload.wav`
    - `... vNNN-A.wav`
    - `... vNNN-B.wav`
  - falls back to the visible page title only when there is no ledger entry
- `_read_cover_page_guard()`
  - reads visible metadata from the active song page
  - verifies both:
    - model tag like `v5` / `v6`
    - `Cover of` metadata
- `download_cover()`
  - navigates to `https://suno.com/song/<song_id>`
  - runs the cover-page guard
  - if the guard fails, returns a refusal and does not download
  - if the guard passes, tries UI download first:
    - `More`
    - `Download`
    - `WAV Audio`
  - if the nested `WAV Audio` item does not become clickable in headless mode,
    it falls back to:
      - `POST https://studio-api.prod.suno.com/api/gen/<song_id>/convert_wav/`
      - `GET https://cdn1.suno.ai/<song_id>.wav`
- `upload_audio()`
  - records source uploads in the ledger as `v###-Upload`
  - selects the default `Amira` workspace on the create page before upload
- `create_cover()`
  - seeds the per-song counter
  - auto-fills the title as `Base Title v###` when `title=""`
  - records returned cover `song_id`s as `Base Title v###-A`, `Base Title v###-B`, etc.
  - reasserts the exact `Amira` workspace after audio attachment

Important detail:

- The fallback is still tied to the explicit `song_id`.
- The new guard prevents fallback from running on a page that is not visibly a
  generated cover.

### `server.py`

The tool documentation was updated so future agents know that:

- `suno_download_cover()` requires visible cover markers before it proceeds
- downloaded WAV filenames are resolved from the per-song ledger
- the title field should usually be left blank so the MCP can auto-number the
  cover as `Base Title v###`

---

## Verified Results

### Successful cover download

Known-good generated cover page:

- Song UUID: `8827a4da-a93d-45f5-992b-23e3cee39517`
- Expected page traits:
  - Suno song page
  - visible model tag `v5`
  - visible `Cover of`

Verified result:

- Saved file:
  - `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE/1.01.0 OVERTURE v012-A.wav`
- Size:
  - `40.9 MB`

### Successful direct WAV download with ledger naming

Known-good seeded cover song ID:

- Song UUID: `1df146af-53b1-4cf0-bfd6-1b702322b561`
- Ledger-resolved filename:
  - `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE/1.01.0 OVERTURE v012-A.wav`

Verified result:

- `suno_download_wav(song_id="1df146af-53b1-4cf0-bfd6-1b702322b561", output_path="/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews")`
  - Result: `✅ Downloaded WAV: /Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE/1.01.0 OVERTURE v012-A.wav`
  - Size: `38.4 MB`

### Fresh restart run

This is the clean rerun after the interruption/crash:

- Fresh export source:
  - `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE v011-Upload.wav`
- Uploaded Suno source song ID:
  - `e8d6d18e-fdfc-40ae-bb79-81e7eeacda18`
- Cover submission layout:
  - Set 1: `v012` orchestral family
  - Set 2: `v013` orchestral family
  - Set 3: `v014` orchestral family
- Each submission produced two completed song IDs on Suno, and the downloads were stored directly in the song folder as:
  - `1.01.0 OVERTURE v012-A.wav`
  - `1.01.0 OVERTURE v012-B.wav`
  - `1.01.0 OVERTURE v013-A.wav`
  - `1.01.0 OVERTURE v013-B.wav`
  - `1.01.0 OVERTURE v014-A.wav`
  - `1.01.0 OVERTURE v014-B.wav`
- Resulting WAV filenames:
  - `1.01.0 OVERTURE v011-Upload.wav`
  - `1.01.0 OVERTURE v012-A.wav`
  - `1.01.0 OVERTURE v012-B.wav`
  - `1.01.0 OVERTURE v013-A.wav`
  - `1.01.0 OVERTURE v013-B.wav`
  - `1.01.0 OVERTURE v014-A.wav`
  - `1.01.0 OVERTURE v014-B.wav`

Useful note:

- The first download attempt for a given duplicate output can fail with a `convert_wav` 400 or an empty UI submenu.
- Retrying the same `song_id` after the conversion has had time to settle has been enough to complete the download.

### Verified refusal on the source upload page

Known source-upload song page:

- Song UUID: `165161af-a8bd-4b83-b08a-2b1ffb42d28f`
- This was the uploaded source row from the `1.01.0 OVERTURE v003-Upload` run,
  not the generated cover page.

Verified result:

- `suno_download_cover()` now refuses with:
  - `page is not verified as a generated Suno cover`
  - `Model tag: (missing)`
  - `Cover metadata: (missing)`

This is the intended safeguard.

---

## Exact Reproduction Flow

### 1. Start the MCP server

From the MCP repo:

```bash
rtk bash -lc 'cd "/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp" && venv/bin/python -c "import time, logging, uvicorn; logging.basicConfig(level=logging.INFO); from suno_mcp.server import fastapi_app; fastapi_app.start_time = time.time(); uvicorn.run(fastapi_app, host=\"127.0.0.1\", port=3001)"'
```

Health check:

```bash
rtk curl -s http://127.0.0.1:3001/health
```

### 2. Open the browser session

```bash
rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_open_browser -H "Content-Type: application/json" -d "{\"name\":\"suno_open_browser\",\"arguments\":{\"headless\":true}}" | jq -r .result'
```

### 3. Use the correct Suno naming before download

Before downloading, make sure the generated song is already titled the way it
should be saved, or leave `title=""` and let the MCP auto-assign the next
version for that song.

Examples:

- Upload source:
  - `1.01.0 OVERTURE v011-Upload`
- Generated cover:
  - `1.01.0 OVERTURE v012`

The MCP now saves the WAV using the per-song ledger and the canonical
`v###-A/B` or `v###-Upload` naming.

### 4. Confirm the page is a generated cover

A correct generated cover page must visibly show:

- the song title
- a model tag such as `v5`
- `Cover of ...`

Do not use the lower library cards or unrelated three-dot menus.

The relevant menu is the song action row menu, the one after:

- `Like`
- `Dislike`
- `Share`
- `More`

### 5. Download with the MCP

```bash
rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_download_cover -H "Content-Type: application/json" -d "{\"name\":\"suno_download_cover\",\"arguments\":{\"song_id\":\"8827a4da-a93d-45f5-992b-23e3cee39517\",\"download_path\":\"/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews\"}}" | jq -r .result'
```

Expected behavior:

- the tool navigates to the exact song page
- the guard checks for `vN` and `Cover of`
- the tool tries:
  - `More`
  - `Download`
  - `WAV Audio`
- if the UI submenu does not surface correctly in headless mode, the tool falls
  back to the direct Suno conversion endpoint for that same `song_id`
- the WAV lands in the song folder with the canonical ledger filename

### 6. Verify the refusal path if needed

```bash
rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_download_cover -H "Content-Type: application/json" -d "{\"name\":\"suno_download_cover\",\"arguments\":{\"song_id\":\"165161af-a8bd-4b83-b08a-2b1ffb42d28f\",\"download_path\":\"/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews\"}}" | jq -r .result'
```

Expected result:

- refusal
- no WAV download

---

## Current Naming Convention

Use this as the simple operating rule:

- Source upload file on disk:
  - `Song Title v011-Upload.wav`
- Suno title for the upload:
  - `Song Title v011-Upload`
- Suno cover title:
  - `Song Title v012`
- Downloaded cover files:
  - `Song Title v012-A.wav`
  - `Song Title v012-B.wav`

The `A` and `B` suffixes are always capitalized.

The version number resets per song because the ledger key is the song's base
title, not a global counter.

---

## Current Limitation

The headless browser still does not always expose the nested `WAV Audio`
submenu item after `Download`.

Current status:

- safe: yes
- correct by song UUID: yes
- correctly named on disk: yes
- direct visible UI submenu success in headless mode: not fully reliable yet

Because of the new guard, this limitation is now operationally safe:

- right page required
- cover metadata required
- exact `song_id` required
- wrong source page refused

---

## What Future Agents Must Not Regress

Do not reintroduce any of the following:

- local fake version numbering for downloaded WAVs
- downloading a WAV before confirming the page is a generated cover
- assuming any song page is acceptable for `suno_download_cover()`
- concurrent `suno_download_cover()` calls in the same session
- silently accepting a page that lacks `vN` and `Cover of`

If the UI submenu becomes reliable later, keep the guard anyway.
