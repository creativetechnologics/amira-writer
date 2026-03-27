#!/usr/bin/env python3
"""Experiment: no-piano/keyboard/keys batch (5 songs × orchestral + chamber).

Songs chosen at random from the Amira batch (must exclude recently tested):
  1.20.0  GRACE
  1.23.0  REASON
  2.24.0  ALONE
  8.01.0  STREETLIGHTS
  9.14.0  SHEMA

Negative prompt adds -piano, -keyboard, -keys on top of the canonical
percussion exclusions.  Goal: reduce or eliminate piano/keys bleeds in
the orchestral/chamber renders.

ALWAYS generates fresh WAV exports — never reuses old uploads.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

PROJECT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
PREVIEWS = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno")
EXPORT_SCRIPT = Path("/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh")
SCORE_BIN = Path("/Volumes/Storage VIII/Programming/Amira Writer/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore")
LOG = Path("/Volumes/Storage VIII/Programming/Amira Writer/Suno/test-no-piano-log.jsonl")
UUID_RE = re.compile(r"[0-9a-fA-F-]{36}")
VERSION_RE = re.compile(r" v(\d{3})(?:-([A-Za-z]+))?\.wav$", re.I)
EXPORT_RETRIES = 3

# --- Canonical prompts ---

ORCHESTRAL_INSTRUMENTAL = (
    "orchestra, instrumental, same tempo, same structure, "
    "restrained dynamics, same key, same keychanges, same melodies"
)

CHAMBER_INSTRUMENTAL = (
    "chamber music, adagio for strings, lyrical woodwinds, instrumental, "
    "same tempo, same structure, restrained dynamics"
)

# Extended negative: adds -piano, -keyboard, -keys to the canonical set
NEGATIVE = "-drums, -percussion, -cymbals, -snare, -kick, -piano, -keyboard, -keys"

# --- Songs to export ---

SONGS_TO_EXPORT = {
    "1.20.0 GRACE":        "1.20.0 - GRACE.ows",
    # REASON keeps its legacy Suno output title, but the current score file on disk
    # is numbered 1.32.1.
    "1.23.0 REASON":       "1.32.1 - REASON.ows",
    "2.24.0 ALONE":        "2.24.0 - ALONE.ows",
    "8.01.0 STREETLIGHTS": "8.01.0 - STREETLIGHTS.ows",
    "9.14.0 SHEMA":        "9.14.0 - SHEMA.ows",
}

# --- Cover jobs (2 per song = 10 total) ---

JOBS = [
    # GRACE
    {
        "name": "1. GRACE (orchestral)",
        "base_title": "1.20.0 GRACE",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "2. GRACE (chamber)",
        "base_title": "1.20.0 GRACE",
        "style": CHAMBER_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    # REASON
    {
        "name": "3. REASON (orchestral)",
        "base_title": "1.23.0 REASON",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "4. REASON (chamber)",
        "base_title": "1.23.0 REASON",
        "style": CHAMBER_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    # ALONE
    {
        "name": "5. ALONE (orchestral)",
        "base_title": "2.24.0 ALONE",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "6. ALONE (chamber)",
        "base_title": "2.24.0 ALONE",
        "style": CHAMBER_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    # STREETLIGHTS
    {
        "name": "7. STREETLIGHTS (orchestral)",
        "base_title": "8.01.0 STREETLIGHTS",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "8. STREETLIGHTS (chamber)",
        "base_title": "8.01.0 STREETLIGHTS",
        "style": CHAMBER_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    # SHEMA
    {
        "name": "9. SHEMA (orchestral)",
        "base_title": "9.14.0 SHEMA",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "10. SHEMA (chamber)",
        "base_title": "9.14.0 SHEMA",
        "style": CHAMBER_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
]


def log_event(event: str, **data):
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **data}
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=True) + "\n")
    print(json.dumps(record, indent=None, ensure_ascii=True), flush=True)


def next_version(base_title: str) -> int:
    """Find next available version number for a song."""
    highest = 0
    song_dir = PREVIEWS / base_title
    if song_dir.exists():
        for wav in song_dir.glob("*.wav"):
            match = VERSION_RE.search(wav.name)
            if match:
                highest = max(highest, int(match.group(1)))
    return highest + 1


def export_song(base_title: str, song_file: str) -> Path:
    """Export a fresh WAV for the given song. Returns the upload path."""
    version = next_version(base_title)
    song_dir = PREVIEWS / base_title
    song_dir.mkdir(parents=True, exist_ok=True)
    upload_path = song_dir / f"{base_title} v{version:03d}-Upload.wav"

    log_event("export_start", base_title=base_title, version=version, output=str(upload_path))

    env = os.environ.copy()
    env["NOVOTRO_ALLOW_BLUETOOTH_OUTPUT"] = "1"
    env["NOVOTRO_SCORE_BIN"] = str(SCORE_BIN)

    for attempt in range(1, EXPORT_RETRIES + 1):
        if upload_path.exists():
            try:
                upload_path.unlink()
            except OSError:
                pass

        proc = subprocess.run(
            [
                str(EXPORT_SCRIPT),
                "--project", str(PROJECT),
                "--song-path", f"Songs/{song_file}",
                "--output", str(upload_path),
            ],
            env=env,
            capture_output=True,
            text=True,
        )

        if proc.returncode == 0:
            size = upload_path.stat().st_size if upload_path.exists() else 0
            log_event("export_ok", base_title=base_title, path=str(upload_path), size=size)
            return upload_path

        is_recoverable = proc.returncode in (133, 134, 139) or proc.returncode >= 128
        if attempt < EXPORT_RETRIES and is_recoverable:
            log_event("export_retry", base_title=base_title, attempt=attempt, rc=proc.returncode, reason="signal")
            time.sleep(5)
            continue

        if proc.returncode == 10:
            log_event("export_warning", base_title=base_title, warning="silent_wav", path=str(upload_path))
            return upload_path  # Let it proceed — waveform may still be usable

        raise RuntimeError(
            f"Export failed for {base_title} (rc={proc.returncode}): {proc.stderr[-500:]}"
        )

    raise RuntimeError(f"Export exhausted {EXPORT_RETRIES} retries for {base_title}")


def call_tool(name: str, arguments: dict, timeout: int = 3600) -> dict:
    payload = json.dumps({"name": name, "arguments": arguments}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:3001/api/v1/tools/{name}",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == 3:
                raise
            log_event("tool_retry", tool=name, attempt=attempt + 1, reason=str(exc))
            time.sleep(5)
    raise RuntimeError("unreachable")


def extract_song_ids(result_text: str) -> list[str]:
    match = re.search(r"Song IDs: (\[.*\])", result_text)
    if not match:
        return UUID_RE.findall(result_text)[:2]
    seen = []
    for sid in UUID_RE.findall(match.group(1)):
        if sid not in seen:
            seen.append(sid)
    return seen[:2]


def wait_complete(song_id: str, timeout_seconds: int = 600) -> bool:
    started = time.time()
    while time.time() - started < timeout_seconds:
        try:
            resp = call_tool("suno_get_cover_status", {"song_id": song_id}, timeout=120)
        except Exception:
            time.sleep(15)
            continue
        text = resp.get("result", "")
        if "status=complete" in text:
            return True
        if "status=not_found" in text or "❌" in text:
            return False
        time.sleep(10)
    return False


def download_song(song_id: str, job_name: str) -> str:
    for attempt in range(3):
        try:
            resp = call_tool(
                "suno_download_cover",
                {"song_id": song_id, "download_path": str(PREVIEWS)},
                timeout=600,
            )
            result = resp.get("result", "")
            if "❌" not in result:
                return result
        except Exception as exc:
            result = str(exc)
        log_event("download_retry", job=job_name, song_id=song_id, attempt=attempt + 1)
        time.sleep(30)
    return f"FAILED after 3 attempts: {result}"


_UPLOAD_ERROR_PHRASES = (
    "Audio Influence slider not present",
    "not properly attached",
    "Uploaded source never became a usable Cover source",
)

_CAPTCHA_RETRIES = 2
_UPLOAD_RETRIES = 2


def run_job(job: dict, upload_path: Path) -> dict:
    name = job["name"]
    log_event("job_start", job=name, style=job["style"][:80], gender=job["gender"],
              negative=NEGATIVE)

    captcha_attempts = 0
    upload_attempts = 0

    while True:
        try:
            resp = call_tool("suno_create_cover", {
                "file_path": str(upload_path),
                "style": job["style"],
                "lyrics": job["lyrics"],
                "exclude_styles": NEGATIVE,
                "weirdness": 0,
                "style_influence": 30,
                "audio_influence": 95,
                "vocal_gender": job["gender"],
                "title": "",
            })
        except Exception as exc:
            log_event("job_error", job=name, stage="create_cover", error=str(exc))
            return {"job": name, "status": "error", "error": str(exc)}

        result_text = resp.get("result", "")

        if "CAPTCHA" in result_text or "captcha" in result_text.lower():
            if captcha_attempts < _CAPTCHA_RETRIES:
                captcha_attempts += 1
                log_event("job_captcha_recovery", job=name, attempt=captcha_attempts)
                try:
                    call_tool("suno_close_browser", {}, timeout=15)
                except Exception:
                    pass
                time.sleep(5)
                try:
                    call_tool("suno_open_browser", {"headless": True}, timeout=30)
                except Exception:
                    pass
                log_event("job_captcha_wait", job=name, seconds=30,
                          note="Reopened headless browser; retrying")
                time.sleep(30)
                log_event("job_captcha_retry", job=name)
                continue
            log_event("job_captcha", job=name)
            return {"job": name, "status": "captcha"}

        if "❌" in result_text:
            if upload_attempts < _UPLOAD_RETRIES and any(
                phrase in result_text for phrase in _UPLOAD_ERROR_PHRASES
            ):
                upload_attempts += 1
                log_event("job_upload_retry", job=name, attempt=upload_attempts, reason=result_text[:200])
                time.sleep(5)
                continue
            log_event("job_error", job=name, stage="create_cover", error=result_text[:200])
            return {"job": name, "status": "error", "error": result_text[:200]}

        break  # success

    song_ids = extract_song_ids(result_text)
    title_match = re.search(r"^Title: (.+)$", result_text, re.M)
    cover_title = title_match.group(1).strip() if title_match else name

    log_event("job_cover_created", job=name, title=cover_title, song_ids=song_ids)

    if len(song_ids) < 2:
        log_event("job_error", job=name, stage="capture_ids", found=len(song_ids))
        return {"job": name, "status": "error", "error": f"Only {len(song_ids)} IDs found"}

    # Wait for completion
    for sid in song_ids:
        ok = wait_complete(sid)
        if not ok:
            log_event("job_warning", job=name, song_id=sid, issue="did not complete in time")

    # Download both
    downloads = []
    for sid in song_ids:
        dl_result = download_song(sid, name)
        downloads.append(dl_result)
        log_event("job_download", job=name, song_id=sid, result=dl_result[:200])

    log_event("job_done", job=name, title=cover_title, song_ids=song_ids)
    return {"job": name, "status": "done", "title": cover_title, "song_ids": song_ids}


def main():
    log_event("test_start", job_count=len(JOBS), export_count=len(SONGS_TO_EXPORT),
              negative=NEGATIVE,
              note="Experiment: no-piano/keyboard/keys added to negative prompt")

    # Phase 1: Export fresh WAVs
    print("\n" + "=" * 70)
    print("  PHASE 1: FRESH WAV EXPORTS (silent render)")
    print("=" * 70 + "\n")

    upload_paths: dict[str, Path] = {}
    for base_title, song_file in SONGS_TO_EXPORT.items():
        try:
            path = export_song(base_title, song_file)
            upload_paths[base_title] = path
            print(f"  ✅ {base_title}: {path.name} ({path.stat().st_size / 1048576:.1f} MB)")
        except Exception as exc:
            print(f"  ❌ {base_title}: {exc}")
            log_event("export_error", base_title=base_title, error=str(exc))

    # Phase 2: Create covers
    print("\n" + "=" * 70)
    print("  PHASE 2: SUNO COVER GENERATION  [no piano / keyboard / keys]")
    print("=" * 70 + "\n")

    results = []
    for job in JOBS:
        upload = upload_paths.get(job["base_title"])
        if not upload:
            print(f"  ⏭️  {job['name']}: skipped (no export)")
            results.append({"job": job["name"], "status": "skipped"})
            continue

        result = run_job(job, upload)
        results.append(result)
        icon = "✅" if result["status"] == "done" else "⚠️" if result["status"] == "captcha" else "❌"
        print(f"  {icon} {result['job']}: {result['status']}")

    # Summary
    log_event("test_complete", results=results)

    print("\n" + "=" * 70)
    print("  FINAL RESULTS")
    print("=" * 70)
    for r in results:
        status = r["status"]
        icon = "✅" if status == "done" else "⚠️" if status == "captcha" else "❌"
        print(f"  {icon} {r['job']}: {status}")
        if "song_ids" in r:
            for sid in r["song_ids"]:
                print(f"      ID: {sid}")
    print("=" * 70)


if __name__ == "__main__":
    main()
