# Suno WAV Download Guardrails

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

The current solution preserves a safe fallback while adding a hard guard against
wrong-page downloads.

---

## Canonical Rules

### Naming rules

- Upload titles in Suno should end with:
  - `<Song Title> version NNN Upload`
- Generated cover titles in Suno should end with:
  - `<Song Title> version NNN`
- The downloaded WAV filename must match the current Suno song title exactly.
- The MCP must not invent local version numbers.
- If a version number is desired in the downloaded WAV filename, that version
  must be set in Suno before the download occurs.

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
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/server.py`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/Codex Handoff Suno MCP.md`

### `tools.py`

Current behavior:

- `_read_song_title()`
  - reads the visible Suno song title from the page
  - falls back to the browser title if needed
- `_resolve_song_download_target()`
  - creates the song folder from the base title
  - saves the WAV as `<exact current Suno song title>.wav`
  - does not auto-increment local version numbers
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

Important detail:

- The fallback is still tied to the explicit `song_id`.
- The new guard prevents fallback from running on a page that is not visibly a
  generated cover.

### `server.py`

The tool documentation was updated so future agents know that:

- `suno_download_cover()` requires visible cover markers before it proceeds
- downloaded WAV filenames must match the current Suno song title

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
  - `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE/1.01.0 OVERTURE.wav`
- Size:
  - `40.9 MB`

### Verified refusal on the source upload page

Known source-upload song page:

- Song UUID: `165161af-a8bd-4b83-b08a-2b1ffb42d28f`
- This was the uploaded source row from the `1.01.0 OVERTURE version 003` run,
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
should be saved.

Examples:

- Upload source:
  - `1.01.0 OVERTURE version 011 Upload`
- Generated cover:
  - `1.01.0 OVERTURE version 012`

The MCP now saves the WAV using the exact current Suno title.

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
- the WAV lands in the song folder with the exact Suno title as the filename

### 6. Verify the refusal path if needed

```bash
rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_download_cover -H "Content-Type: application/json" -d "{\"name\":\"suno_download_cover\",\"arguments\":{\"song_id\":\"165161af-a8bd-4b83-b08a-2b1ffb42d28f\",\"download_path\":\"/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews\"}}" | jq -r .result'
```

Expected result:

- refusal
- no WAV download

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
