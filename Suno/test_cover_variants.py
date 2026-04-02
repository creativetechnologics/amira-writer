#!/usr/bin/env python3
"""Test cover generation with different prompt variants.

ALWAYS generates fresh WAV exports — never reuses old uploads.

Runs 7 covers to validate:
1. Instrumental orchestral (TIME OF WAR)
2. Vocal male orchestral (HOW - Johnny solo)
3. Vocal mixed orchestral (THE CONFESSION - Luke + Amira)
4. Chamber music (SOMETHING MORE)
5. Chamber/orchestra hybrid (SOMETHING MORE)
6. Chamber music (THE RETURN)
7. Chamber/orchestra hybrid (THE RETURN)
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
SCORE_BIN = Path("/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/.build/arm64-apple-macosx/release/Score")
LOG = Path("/Volumes/Storage VIII/Programming/Amira Writer/Suno/test-cover-variants-log.jsonl")
UUID_RE = re.compile(r"[0-9a-fA-F-]{36}")
VERSION_RE = re.compile(r" v(\d{3})(?:-([A-Za-z]+))?\.wav$", re.I)
EXPORT_RETRIES = 3

# --- Canonical prompts ---

ORCHESTRAL_INSTRUMENTAL = (
    "orchestra, instrumental, same tempo, same structure, "
    "restrained dynamics, same key, same keychanges, same melodies"
)

ORCHESTRAL_VOCAL = (
    "orchestra, classical voice, same tempo, same structure, "
    "restrained dynamics, same key, same keychanges, same melodies"
)

CHAMBER_VOCAL = (
    "chamber music, adagio for strings, lyrical woodwinds, classical voice, "
    "same tempo, same structure, restrained dynamics"
)

CHAMBER_HYBRID = (
    "chamber music, orchestra, adagio for strings, lyrical woodwinds, classical voice, "
    "same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
)

NEGATIVE = "-drums, -percussion, -cymbals, -snare, -kick"

# --- Lyrics ---

HOW_LYRICS = """JOHNNY:
What are these images
that keep developing in me?
Why does each frame feel like a crime?

How can I shelve them
and wake to another morning?
Why can't this lens let me sleep?

How can one instant
turn into a hundred frozen pictures?
Why do they stay in me?

My life was so simple,
why can't I stop seeing
the dust, the wall, the faces following me?

How can I think,
when all these frozen negatives
never stop following me?

What if I'm not witness,
but part of what feeds on sorrow?
When will this war let me sleep?"""

CONFESSION_LYRICS = """LUKE:
Don't you get it?
I was a soldier.
I had no choice —
but I made one that day.

I've sent men to their graves.
With no good reason at all.
What am I supposed to say?

I became the very thing,
that I swore I'd never become.
What is this supposed to mean?

But here's what I know:
I watched you bind a stranger
while the radio called her danger.
I watched myself stay quiet
when quiet was the easier sin.

Standing here beside you,
I can hear how wrong that silence was.
Staying here beside you —
that is the first choice I've made without orders.

I love you. Not as rescue.
Not as pardon.
As the truth I can't leave.

AMIRA:
I know what you are.
I know what you've done.
I know what you let happen.

Luke, you did not stop it then.
You were inside its reach.
It wasn't you alone who killed those men,
it was the system you still served.

Now I'm not saying what you did was right,
but what now matters is you face the truth.
You didn't know enough to stop it then,
but truth is what you owe the dead.

Luke, I know you're in pain,
but I will see what you do with this truth.

BOTH:
There is truth we cannot bury.
There is grief we do not choose.
And we carry both anyway."""

# --- Songs to export (unique songs — some get multiple cover variants) ---

SONGS_TO_EXPORT = {
    "1.25.0 TIME OF WAR": "1.25.0 - TIME OF WAR.ows",
    "1.26.0 HOW": "1.26.0 - HOW.ows",
    "2.09.0 THE CONFESSION": "2.09.0 - THE CONFESSION.ows",
    "1.44.0 SOMETHING MORE (Act I Finale)": "1.44.0 - SOMETHING MORE (Act I Finale).ows",
    "1.34.0 THE RETURN": "1.34.0 - THE RETURN.ows",
}

# --- Cover jobs (reference base_title, all share exports within this batch) ---

JOBS = [
    {
        "name": "1. TIME OF WAR (orchestral instrumental)",
        "base_title": "1.25.0 TIME OF WAR",
        "style": ORCHESTRAL_INSTRUMENTAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "2. HOW (orchestral vocal, male)",
        "base_title": "1.26.0 HOW",
        "style": ORCHESTRAL_VOCAL,
        "lyrics": HOW_LYRICS,
        "gender": "male",
    },
    {
        "name": "3. THE CONFESSION (orchestral vocal, male)",
        "base_title": "2.09.0 THE CONFESSION",
        "style": ORCHESTRAL_VOCAL,
        "lyrics": CONFESSION_LYRICS,
        "gender": "male",
    },
    {
        "name": "4. SOMETHING MORE (chamber)",
        "base_title": "1.44.0 SOMETHING MORE (Act I Finale)",
        "style": CHAMBER_VOCAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "5. SOMETHING MORE (chamber hybrid)",
        "base_title": "1.44.0 SOMETHING MORE (Act I Finale)",
        "style": CHAMBER_HYBRID,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "6. THE RETURN (chamber)",
        "base_title": "1.34.0 THE RETURN",
        "style": CHAMBER_VOCAL,
        "lyrics": "[Instrumental]",
        "gender": "",
    },
    {
        "name": "7. THE RETURN (chamber hybrid)",
        "base_title": "1.34.0 THE RETURN",
        "style": CHAMBER_HYBRID,
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

_CAPTCHA_RETRIES = 2    # how many times we'll stop for a human CAPTCHA solve
_UPLOAD_RETRIES = 2     # how many times we'll retry on upload/attachment errors


def run_job(job: dict, upload_path: Path) -> dict:
    name = job["name"]
    log_event("job_start", job=name, style=job["style"][:80], gender=job["gender"],
              lyrics_len=len(job["lyrics"]))

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
                # Close and re-open browser in headless to get a fresh session
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
            # Check whether this is an upload/attachment error worth retrying
            if upload_attempts < _UPLOAD_RETRIES and any(
                phrase in result_text for phrase in _UPLOAD_ERROR_PHRASES
            ):
                upload_attempts += 1
                log_event("job_upload_retry", job=name, attempt=upload_attempts, reason=result_text[:200])
                time.sleep(5)
                continue
            log_event("job_error", job=name, stage="create_cover", error=result_text[:200])
            return {"job": name, "status": "error", "error": result_text[:200]}

        # Success path — break out of retry loop
        break

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
    log_event("test_start", job_count=len(JOBS), export_count=len(SONGS_TO_EXPORT))

    # Phase 1: Export fresh WAVs for all unique songs
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
    print("  PHASE 2: SUNO COVER GENERATION")
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
