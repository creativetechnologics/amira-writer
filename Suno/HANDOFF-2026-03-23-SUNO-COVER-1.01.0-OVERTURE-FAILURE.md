# Suno Cover Handoff — 1.01.0 OVERTURE
**Date:** 2026-03-23
**Status:** BLOCKED — BBC AU loading failure in headless export

---

## What We Did

### 1. WAV Export (FAILED — silent output)
```bash
NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1 Scripts/export-headless-wav.sh \
  --project "/Volumes/Storage VIII/Programming/Amira - A Modern Opera/Amira.owp" \
  --song-path "Songs/1.01.0 - OVERTURE.ows" \
  --output "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 001.wav"
```

**Result:** 66MB WAV file, but **completely silent** (verified with hexdump — all zeros).

### 2. Root Cause Investigation
The export log shows **ALL 27 BBC Audio Units failed to load**:
```
[Engine] AU load timeout/failed for violins-i: OSStatus error -3000
[Engine] AU load timeout/failed for cellos: OSStatus error -3000
[Engine] AU load timeout/failed for trumpets: OSStatus error -3000
... (all 27 instruments failed)
```

Engine then fell back to looking for SF2 soundfonts, found none for the mapping keys, and muted everything:
```
No sf2Path for mappingKey: __preview__
No instrument loaded for __preview__ — muting sampler
```

### 3. Previous Working Export
- `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/Overture version 031.wav` — **HAS audio** (179.7 sec, verified non-zero PCM values)
- This was created March 19 and works

### 4. auval Output
`auval -a` on Storage VIII shows **only Apple system AUs** — no BBC Symphony Orchestra AUs visible in the registry. Gary says they ARE installed.

---

## Gary's Note
> The BBC AUs ARE installed on my server. We've had almost literally this exact conversation before.

---

## Suno MCP Work

### Server Status
- Suno MCP server running at `http://127.0.0.1:3001`
- Started with:
```bash
cd ~/Library/Application\ Support/Novotro\ Score/suno-mcp
source venv/bin/activate
python -c "import time, logging, uvicorn; logging.basicConfig(level=logging.INFO); from suno_mcp.server import fastapi_app; fastapi_app.start_time = time.time(); uvicorn.run(fastapi_app, host='127.0.0.1', port=3001)"
```

### Upload Status
- `1.01.0 OVERTURE version 001.wav` uploaded to Suno (but silent — useless for cover)
- `Overture version 031.wav` available as fallback source (has audio)

### Suno MCP Issue
- `suno_create_cover()` keeps failing with:
  - "Audio Influence slider not present after Cover mode selection"
  - "found 2 sliders, expected ≥3"
- This happens even when all 3 sliders ARE visible on screen
- The tool's slider detection logic is not correctly counting sliders
- Manual UI navigation through the Cover flow works (upload → Keep Both → Cover → Continue → scroll → sliders visible)

### Cover Presets Ready (not yet submitted)
- **Style:** `orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies`
- **Exclude:** `-drums, -percussion, -cymbals, -snare, -kick`
- **Sliders:** `30 / 95 / 95`
- **Title:** `1.01.0 OVERTURE`
- **Vocal gender:** N/A (instrumental)

---

## Files
| File | Status |
|------|--------|
| `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 001.wav` | Silent (broken) |
| `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/Overture version 031.wav` | Has audio (179.7 sec) |

---

## Next Steps for Next Session
1. **FIX BBC AU LOADING** — Gary says AUs are installed, but auval doesn't see them. Possible causes:
   - AU plugin not in expected location
   - Plugin cache needs rebuild (`auval -r` or `killall coreaudiod`)
   - Something changed since March 19 that broke AU discovery
2. **Re-export 1.01.0 OVERTURE** with BBC AUs working → produces audible WAV
3. **Navigate Suno Cover flow manually** — use `suno_upload_audio` + click sequence (Keep Both → Cover → Continue) rather than `suno_create_cover`
4. **Fill form and submit** — once on the Create page with audio attached and Cover mode active, fill style/exclude fields and set sliders manually via `suno_set_slider` then click Create
5. **Download WAV** — use `suno_download_cover` after generation completes

---

## Related Docs
- `/Volumes/Storage VIII/Programming/Novotro Opera/Suno/HANDOFF-2026-03-23-SUNO-GENERATION.md`
- `/Volumes/Storage VIII/Programming/Novotro Score/docs/superpowers/SUNO-COVER-PRESET-MASTER.md`
- `/Volumes/Storage VIII/Programming/Novotro Score/docs/superpowers/WAV-EXPORT-GUARDRAILS.md`
- `/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/Codex Handoff Suno MCP.md`
