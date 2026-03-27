# Headless Export Result - 1.01.0 OVERTURE

Date: 2026-03-23
Workspace: `/Volumes/Storage VIII/Programming/Novotro Opera`

This note records a successful headless WAV export for the `1.01.0 - OVERTURE.ows` song using the Opera-local Suno export path.

## Canonical Paths Used

- Wrapper script: `/Volumes/Storage VIII/Programming/Novotro Opera/Scripts/export-headless-wav.sh`
- Prebuilt `NovotroScore` binary: `/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore`
- Live project workspace: `/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera`
- Source song: `/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera/Songs/1.01.0 - OVERTURE.ows`
- Export target: `/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav`

## What Happened

1. The first wrapper invocation was rejected because AirPods were connected:
   - `Refusing headless export while AirPods are connected: Gary's AirPods Pro 2`
2. The export was rerun with the documented override:
   - `NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1`
3. The export completed successfully and wrote a new WAV file.

## Successful Command

```bash
NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1 \
NOVOTRO_SCORE_BIN="/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore" \
/Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/export-headless-wav.sh \
  --project "/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera" \
  --song-path "Songs/1.01.0 - OVERTURE.ows" \
  --output "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav"
```

## Export Log Highlights

- `Opening project: /Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera`
- `Selecting song: Songs/1.01.0 - OVERTURE.ows`
- `Song playback ready in memory.`
- `Rendering ticks 0...21120`
- `[AudioUnitManager] Found 8 Audio Unit instruments`
- `Exported 1.01.0 - Overture to /Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav`

## Output Verification

- File size: `65.8M`
- `afinfo` reported:
  - `2 ch, 48000 Hz, Float32, interleaved`
  - estimated duration: `179.700000 sec`
- `ffmpeg volumedetect` reported:
  - `mean_volume: -22.2 dB`
  - `max_volume: -5.4 dB`

Those amplitude numbers confirm the file is not silent.

## Notes

- The headless export path is still working when the BBC Symphony Audio Unit is discoverable in the session.
- The wrapper guard against connected AirPods is still active and must be overridden explicitly when testing from a Bluetooth audio environment.
- This run used the Opera-local wrapper and the vendored `NovotroScore` binary; it did not rely on the retired standalone Novotro Score app workflow.

## Reproduction Checklist

Use this exact sequence if you need to reproduce the WAV export later:

1. Confirm the BBC AU registry is visible in the session:

   ```bash
   rtk bash -lc 'auval -a 2>/dev/null | rg -i "bbc|spitfire|symphony"'
   ```

   Expected result: `aumu Sant SpFi - Spitfire Audio: BBC Symphony Orchestra`

2. Confirm the source song exists in the live project workspace:

   - Project: `/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera`
   - Song: `/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera/Songs/1.01.0 - OVERTURE.ows`

3. Export with the Opera-local wrapper and the prebuilt `NovotroScore` binary:

   ```bash
   NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1 \
   NOVOTRO_SCORE_BIN="/Volumes/Storage VIII/Programming/Novotro Opera/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore" \
   /Volumes/Storage\ VIII/Programming/Novotro\ Opera/Scripts/export-headless-wav.sh \
     --project "/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera" \
     --song-path "Songs/1.01.0 - OVERTURE.ows" \
     --output "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav"
   ```

4. If the wrapper refuses the run because AirPods are connected, rerun with `NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1` as shown above.

5. Verify the WAV:

   ```bash
   rtk bash -lc 'afinfo "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav" | sed -n "1,25p"'
   rtk bash -lc 'ffmpeg -hide_banner -i "/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav" -af volumedetect -f null - 2>&1 | rg -n "mean_volume|max_volume"'
   ```

   Expected result: `mean_volume` around `-22.2 dB`, `max_volume` around `-5.4 dB`, and `estimated duration: 179.700000 sec`

## Suno Conversion Checklist

This run used the local Suno MCP server at `http://127.0.0.1:3001`.

1. Confirm the server is alive:

   ```bash
   rtk bash -lc 'curl -s http://127.0.0.1:3001/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"status\"), d.get(\"tools_loaded\"), d.get(\"version\"))"'
   ```

2. Confirm browser/session state:

   ```bash
   rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_get_status -H "Content-Type: application/json" -d "{\"name\":\"suno_get_status\",\"arguments\":{}}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"result\"))"'
   ```

3. Open the Suno browser in headed mode:

   ```bash
   rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_open_browser -H "Content-Type: application/json" -d "{\"name\":\"suno_open_browser\",\"arguments\":{\"headless\":false}}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"result\"))"'
   ```

4. Upload the exported WAV:

   ```bash
   rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_upload_audio -H "Content-Type: application/json" -d "{\"name\":\"suno_upload_audio\",\"arguments\":{\"file_path\":\"/Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav\"}}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"result\"))"'
   ```

   Result on this run: `✅ Audio uploaded and trim saved: /Volumes/Storage VIII/Users/gary/Desktop/Novotro Previews/1.01.0 OVERTURE version 003.wav`

5. Inspect the page and capture the uploaded song link:

   - The page was `https://suno.com/create`
   - The uploaded item appeared as `1.01.0 OVERTURE version 003`
   - The first discovered link for that row was:
     - `/song/165161af-a8bd-4b83-b08a-2b1ffb42d28f`

6. Create the cover from the Suno song ID rather than the raw file path if the direct file-path path refuses the slider attachment:

   ```bash
   rtk bash -lc 'curl -s -X POST http://127.0.0.1:3001/api/v1/tools/suno_create_cover -H "Content-Type: application/json" -d "{\"name\":\"suno_create_cover\",\"arguments\":{\"song_id\":\"165161af-a8bd-4b83-b08a-2b1ffb42d28f\",\"style\":\"orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies\",\"exclude_styles\":\"drums, percussion, cymbals, snare, kick\",\"weirdness\":0,\"style_influence\":30,\"audio_influence\":95,\"title\":\"1.01.0 OVERTURE\"}}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"result\"))"'
   ```

7. If Suno reports CAPTCHA, stop and wait for a manual solve in the visible browser window. Do not try to work around the CAPTCHA.

8. After CAPTCHA is cleared, rerun the `suno_create_cover` call, poll with `suno_get_cover_status`, and download the generated WAV with `suno_download_cover`.

## Current Suno Run State

The conversion is currently paused at the CAPTCHA step.

Observed response from `suno_create_cover`:

```text
⚠️ CAPTCHA required — solve in the browser window and retry. create_disabled=False request_count=2 lyrics_len=14 style_len=114 exclude_len=39 title_len=15 captcha_required=True captcha_visible=True
```

Current browser state at pause:

- URL: `https://suno.com/create`
- Logged in heuristic: `True`
- Page ready: `True`
- CAPTCHA visible: `True`

Once the CAPTCHA is solved manually, retry the same `suno_create_cover` command, then poll the resulting song ID and download the WAV locally.
