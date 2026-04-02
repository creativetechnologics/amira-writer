# Suno Cover Generation Pipeline — Handoff Document
*Last updated: 2026-03-25. Written for model handoff after a long session.*

---

## 1. What This Is

An automated pipeline that takes Gary's opera scores (from the Novotro Score app / `.ows` files), exports them as WAV files, and uploads them to Suno AI to generate orchestral or chamber music "covers" — i.e., AI re-orchestrations. The whole thing runs headlessly, no GUI, no Chrome windows. Ever.

The show is **Amira — A Modern Opera**. Songs are numbered like `1.20.0 GRACE`, `2.09.0 THE CONFESSION`, etc. Act numbers prefix the song number.

---

## 2. Key Paths

| Thing | Path |
|---|---|
| **Opera project (source scores)** | `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/` |
| **Song files (`.ows`)** | `…/Amira - A Modern Opera/Songs/*.ows` |
| **Output previews (WAV downloads)** | `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno/` |
| **MCP server source** | `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/suno_mcp/` |
| **Main tools file** | `…/suno_mcp/tools/basic/tools.py` |
| **Browser/utils file** | `…/suno_mcp/tools/shared/utils.py` |
| **FastAPI server** | `…/suno_mcp/server.py` |
| **Test scripts** | `/Volumes/Storage VIII/Programming/Amira Writer/Suno/` |
| **Archived historical notes/scripts** | `/Volumes/Storage VIII/Programming/Amira Writer/Suno/archive/` |
| **Export shell script** | `/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh` |
| **Score CLI binary** | `/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/.build/arm64-apple-macosx/release/Score` |
| **MCP server log** | `/private/tmp/suno-mcp-server.log` |
| **Chromium persistent profile** | `…/suno-mcp/chromium-data/` |

**CRITICAL:** The opera project is at `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/` — NOT in `~/Documents/`. If you see `Project not found` errors during export, this is why.

---

## 3. The MCP Server

### What It Is
A FastAPI server (wrapping FastMCP) that drives a persistent headless Chromium session via Playwright to automate Suno AI. It exposes tools via HTTP at port **3001**.

### How to Start It
```bash
cd "/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp"
nohup python3 -m uvicorn suno_mcp.server:fastapi_app \
  --host 127.0.0.1 --port 3001 --log-level warning \
  > /private/tmp/suno-mcp-server.log 2>&1 &
```

Check it's alive:
```bash
curl -s http://127.0.0.1:3001/health
# → {"status":"ok","version":"1.0.0","uptime":...,"tools_loaded":27}
```

### How to Restart It After Code Changes
```bash
kill $(lsof -ti tcp:3001)
rm -f "…/suno-mcp/chromium-data/Singleton*"  # clean stale locks
# wait 2 seconds, then start as above
```

### Key Tools (Called via HTTP POST to `/api/v1/tools/<name>`)
- `suno_open_browser` — open/init headless browser (always headless, ignores any headless param)
- `suno_close_browser` — close browser session
- `suno_create_cover` — the main workhorse (see §5)
- `suno_get_cover_status` — poll for completion
- `suno_download_cover` — download finished WAV to a local path
- `suno_get_status` — debug: shows current URL, auth state, etc.
- `suno_screenshot` — takes a headless screenshot for debugging

---

## 4. ABSOLUTE RULE: Always Headless

**Gary has been extremely clear about this. Chrome must NEVER open a visible window. Not for CAPTCHA, not for debugging, not ever.**

The headless enforcement is now hard-coded at three levels:

1. **`utils.py` → `ensure_browser()`**: First line is `headless = True` — no matter what any caller passes.
2. **`tools.py` → `open_browser()`**: Same override at the top of the method.
3. **`tools.py` → `_current_headless_preference()`**: Always returns `True`, unconditionally.

If CAPTCHA appears:
- The server closes the browser session (to get a fresh fingerprint) and returns an error.
- The test script catches this, closes/reopens the browser headlessly, waits 30s, and retries.
- It does NOT open a visible window. Ever.

To verify no visible browser is running:
```bash
grep -r "headless=False\|headless = False" \
  "/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/src/"
# Must return: No matches found
```

---

## 5. The Cover Creation Flow (`suno_create_cover`)

This is the most complex tool. There are two code paths:

### PATH A — Suno library song ID (song already on Suno)
1. Navigate to `suno.com/songs/<song_id>`
2. Click the three-dot menu → "Cover" menu item
3. Wait for the "Audio Influence" slider to appear (confirms audio attached)
4. Fill in style prompt, exclude_styles, weirdness, style_influence, audio_influence
5. Submit

### PATH B — Local WAV file upload (used in all our test scripts)
1. Navigate to `suno.com/create`
2. Click "Cover" button
3. Click "Upload" tab
4. Upload the WAV file
5. **Wait up to 120 seconds** for the uploaded song row to appear (large files like 90+ MB can take a long time)
6. Click the uploaded song row to select it as the cover source
7. Wait for the "Audio Influence" slider to appear
8. Fill in prompts and submit

### Critical Quirk: Retry Loop Bug (Fixed)
`_open_cover_from_song_id` has a retry loop (`for attempt in range(max_attach_attempts)`). The failure checks **must be inside the loop** with `continue` on failure and `return` on success. If they're outside, the loop always runs all iterations even after a successful first attempt — which re-navigates and destroys the work. This was a real bug that was fixed; keep it that way.

### Timeouts to Know About
- **Upload poll** (waiting for uploaded song row): 120 seconds × 1s = 120s max
- **Cover button wait**: 60 seconds
- **Attachment detection** (`_wait_for_cover_audio_attachment`): 25 polls × 1.5s + 5 rechecks × 10s = ~87.5s total
- **PATH B attachment wait**: 30 polls × 1.5s + 5 rechecks × 10s = ~95s total

If a large WAV (90+ MB) times out on upload, increase the 120-iteration poll loop in `_attach_cover_from_file`.

---

## 6. The WAV Export Process

Before covers can be created, we export fresh WAVs from Gary's Score project.

### How It Works
```bash
/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh \
  --project "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera" \
  --song-path "Songs/1.20.0 - GRACE.ows" \
  --output "/path/to/output.wav"
```

Required env vars:
```bash
export NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1
export AMIRA_SCORE_BIN="/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/.build/arm64-apple-macosx/release/Score"
```

### Silent Exports (Critical)
All WAV exports must be **silent** — no audio through speakers. This is handled internally by:
- `AudioUnitSetParameter(outputAU, 14, kAudioUnitScope_Global, 0, 0, 0)`

Exit code 10 = "silent WAV warning" — the export may still be usable, proceed anyway.
Exit codes 128+ or 133/134/139 = signal/crash, retry up to 3 times.
Exit code 1 = fatal, do not retry (likely bad path or missing file).

### Fresh Exports Always
The pipeline **always** generates a new export. Never reuse old `-Upload.wav` files. The version number auto-increments by scanning the output directory for the highest existing `v###` suffix.

### File Naming Convention
```
<base_title> v<NNN>-Upload.wav   ← the source WAV uploaded to Suno
<base_title> v<NNN>-A.wav        ← first generated cover (downloaded from Suno)
<base_title> v<NNN>-B.wav        ← second generated cover (Suno always generates 2)
```

---

## 7. Output Directory Structure

All generated files land here:
```
/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno/
├── 1.20.0 GRACE/
│   ├── 1.20.0 GRACE v007-Upload.wav
│   ├── 1.20.0 GRACE v007-A.wav
│   └── 1.20.0 GRACE v007-B.wav
├── 1.23.0 REASON/
│   └── ...
├── 2.09.0 THE CONFESSION/
│   └── ...
```

Do NOT save anything to the Desktop. Not anymore. It was previously going to `~/Desktop/Novotro Previews/` — that's the old path, now replaced.

---

## 8. Canonical Style Prompts

These are the exact prompts used in cover generation:

```python
ORCHESTRAL_INSTRUMENTAL = (
    "orchestra, instrumental, same tempo, same structure, "
    "restrained dynamics, same key, same keychanges, same melodies"
)

ORCHESTRAL_VOCAL = (
    "orchestra, classical voice, same tempo, same structure, "
    "restrained dynamics, same key, same keychanges, same melodies"
)

CHAMBER_INSTRUMENTAL = (
    "chamber music, adagio for strings, lyrical woodwinds, instrumental, "
    "same tempo, same structure, restrained dynamics"
)

CHAMBER_VOCAL = (
    "chamber music, adagio for strings, lyrical woodwinds, classical voice, "
    "same tempo, same structure, restrained dynamics"
)

CHAMBER_HYBRID = (
    "chamber music, orchestra, adagio for strings, lyrical woodwinds, classical voice, "
    "same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
)
```

### Standard Negative Prompt
```python
NEGATIVE = "-drums, -percussion, -cymbals, -snare, -kick"
```

### No-Piano Experiment Negative Prompt (current experiment)
```python
NEGATIVE = "-drums, -percussion, -cymbals, -snare, -kick, -piano, -keyboard, -keys"
```

Gary is experimenting with removing piano/keys from outputs because the AI keeps adding unwanted percussion and keyboard sounds. The no-piano negative prompt is the current test.

### Cover Parameters (Fixed Values)
```python
weirdness = 0
style_influence = 30
audio_influence = 95
```

---

## 9. Test Scripts

### `test_cover_variants.py`
The original 7-cover validation run. Tests orchestral instrumental, vocal (male), chamber, and chamber-hybrid variants across 5 songs. Song list:
- 1.25.0 TIME OF WAR (orchestral instrumental)
- 1.26.0 HOW (orchestral vocal, male — has full lyrics)
- 2.09.0 THE CONFESSION (orchestral vocal — has full duet lyrics for Luke + Amira)
- 1.44.0 SOMETHING MORE (Act I Finale) (chamber and chamber-hybrid)
- 1.34.0 THE RETURN (chamber and chamber-hybrid)

### `test_no_piano.py`
Current running experiment. 5 songs × 2 variants = 10 jobs. All instrumental. Extended negative prompt includes `-piano, -keyboard, -keys`. Songs:
- 1.20.0 GRACE
- 1.23.0 REASON
- 2.24.0 ALONE
- 8.01.0 STREETLIGHTS
- 9.14.0 SHEMA

**Status as of handoff:** Running. Exports working after PROJECT path fix. PID 2953, log at `/private/tmp/no-piano-test.log`.

**Numbering quirk:** the score file for REASON is currently stored on disk as `Songs/1.32.1 - REASON.ows`, but the Suno batch/test scripts still use the legacy output title `1.23.0 REASON` so existing preview folders and version history stay consistent.

### How to Run a Test Script
```bash
cd "/Volumes/Storage VIII/Programming/Amira Writer/Suno"
nohup python3 test_no_piano.py > /private/tmp/no-piano-test.log 2>&1 &
echo "PID: $!"
# Monitor:
tail -f /private/tmp/no-piano-test.log
```

---

## 10. How to Create a New Test Script

Copy `test_no_piano.py` as a template. Change:
1. `SONGS_TO_EXPORT` dict — `"base_title": "song_file.ows"` pairs
2. `JOBS` list — each job needs `name`, `base_title`, `style`, `lyrics`, `gender`
3. `NEGATIVE` — the exclude_styles string
4. `LOG` path — give it a unique log file name

Make sure `PROJECT` stays as:
```python
PROJECT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
```
And `PREVIEWS` as:
```python
PREVIEWS = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno")
```

---

## 11. Error Handling Quirks

### "Audio Influence slider not present" / "not properly attached"
The cover audio attachment failed. The test script auto-retries up to `_UPLOAD_RETRIES = 2` times. If it keeps happening, it usually means:
- Suno's UI changed (timing issue) → increase wait times in `_wait_for_cover_audio_attachment`
- The uploaded WAV was rejected (too large, corrupted) → check file size and integrity

### "Uploaded source never became a usable Cover source"
The 120-second poll for the uploaded song row timed out. Most common with large files (90+ MB). Fix: increase the `range(120)` in `_attach_cover_from_file` in `tools.py`.

### CAPTCHA
The test script closes and reopens the headless browser (always headless, never visible) and retries. Up to `_CAPTCHA_RETRIES = 2` times. If CAPTCHA persists across retries, the job returns `status=captcha` and the test moves on.

### "Song IDs: []" (empty)
The network interceptor missed the response. The UUID extractor falls back to scanning all UUIDs in the result text. If still empty, the cover was likely created but IDs weren't captured — navigate to `suno.com/library` to find the newest song manually.

### Export rc=1 "Project not found"
Wrong `PROJECT` path in the test script. Should be:
`/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera`
(Not in `Documents/`)

---

## 12. Stealth / Anti-Bot Measures

The browser has extensive fingerprint spoofing in `utils.py`'s `STEALTH_INIT_SCRIPT`:
- Spoofs `navigator.webdriver` to `undefined`
- Mocks `speechSynthesis.getVoices()` (absent in headless = bot signal)
- Fixes `screen.colorDepth` / `screen.pixelDepth` (headless reports 0)
- Overrides `document.hasFocus()` to return `true`
- Overrides `document.visibilityState` to `'visible'`
- Spoofs WebGL renderer (headless uses SwiftShader = detectable)
- Masks `outerWidth`/`outerHeight` (zero in headless)

Browser launch args include:
- `--disable-blink-features=AutomationControlled`
- `--window-size=1280,800` / `--window-position=0,0`
- `--autoplay-policy=no-user-gesture-required`
- `--disable-infobars`

`ignore_default_args` removes:
- `--enable-automation`
- `--hide-scrollbars`
- `--mute-audio`

---

## 13. Current State at Handoff

| Item | Status |
|---|---|
| MCP server | Running, PID 43161, port 3001 |
| No-piano test | Running, PID 2953 |
| Headless enforcement | Hard-coded at 3 levels, zero `headless=False` in codebase |
| Output directory | `/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno/` |
| PROJECT path bug | Fixed in both test scripts (was pointing to `Documents/`) |
| Cover variant test (7 covers) | Complete — all 7 succeeded |
| No-piano experiment | In progress — 10 jobs (5 songs × orch + chamber) |

### What's Next After No-Piano Results
- Review the no-piano covers to see if piano/keys are gone
- If still present, try adding `-strings, piano` or rephrasing as `no piano, no keyboard`
- If successful, apply the no-piano negative to future batches
- Gary is still working on reducing unwanted percussion and keyboard bleed

---

## 14. How to Monitor a Running Test

```bash
# Live follow:
tail -f /private/tmp/no-piano-test.log

# Just the key events (no noise):
grep -E '"event": "(job_done|job_error|export_ok|test_complete|job_cover_created)"' \
  /private/tmp/no-piano-test.log

# Check if still running:
ps aux | grep test_no_piano | grep -v grep
```

---

## 15. Session Log Reference

Session memory for this project lives at:
```
~/.claude/projects/-Volumes-Storage-VIII-Programming-Novotro-Opera-Suno/memory/
```

Full session transcript (for recovering any code or error detail from this session):
```
/Volumes/Storage VIII/Users/gary/.claude/projects/-Volumes-Storage-VIII-Programming-Novotro-Opera-Suno/facb97f9-4ad0-40bb-89a5-d093913059f8.jsonl
```
