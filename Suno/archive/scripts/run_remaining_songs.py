#!/usr/bin/env python3
"""
Process remaining Amira opera songs: 8.04.0 NIGHTFALL and all 9.xx songs.
Also downloads pending 8.03.0 LUKE AND AMIRA covers.
"""

import ast
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

# Force unbuffered output
os.environ["PYTHONUNBUFFERED"] = "1"

PREVIEWS_DIR = "/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno"
PROJECT_DIR = "/Volumes/Storage VIII/Users/gary/Documents/Amira - A Modern Opera"
EXPORT_SCRIPT = "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh"
JSONL_LOG = "/Volumes/Storage VIII/Programming/Amira Writer/Suno/amira-midi-batch-progress-2026-03-24.jsonl"
NOVOTRO_SCORE_BIN = "/Volumes/Storage VIII/Programming/Amira Writer/Packages/NovotroScore/.build/arm64-apple-macosx/release/NovotroScore"
MCP_BASE = "http://127.0.0.1:3001/api/v1/tools"

COVER_STYLE = "orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
COVER_LYRICS = "[Instrumental]"
COVER_EXCLUDE = "-drums, -percussion, -cymbals, -snare, -kick"

REMAINING_SONGS = [
    ("8.04.0 - NIGHTFALL.ows", "8.04.0 NIGHTFALL"),
    ("9.01.0 - (NEW INTRO).ows", "9.01.0 (NEW INTRO)"),
    ("9.02.0 - (SET FREE).ows", "9.02.0 (SET FREE)"),
    ("9.03.0 - BEST FRIEND.ows", "9.03.0 BEST FRIEND"),
    ("9.04.0 - DANCE IN THE RAIN.ows", "9.04.0 DANCE IN THE RAIN"),
    ("9.05.0 - DINNER AND A MOVIE.ows", "9.05.0 DINNER AND A MOVIE"),
    ("9.06.0 - GONE.ows", "9.06.0 GONE"),
    ("9.07.0 - GUIDING STAR.ows", "9.07.0 GUIDING STAR"),
    ("9.08.0 - HYMN TO THE WEST.ows", "9.08.0 HYMN TO THE WEST"),
    ("9.09.0 - INTERLUDE.ows", "9.09.0 INTERLUDE"),
    ("9.10.0 - LEAVES.ows", "9.10.0 LEAVES"),
    ("9.11.0 - LET IT BEGIN.ows", "9.11.0 LET IT BEGIN"),
    ("9.12.0 - NEARER MY GOD TO THEE.ows", "9.12.0 NEARER MY GOD TO THEE"),
    ("9.13.0 - OLD FINALE.ows", "9.13.0 OLD FINALE"),
    ("9.14.0 - SHEMA.ows", "9.14.0 SHEMA"),
    ("9.15.0 - THE PROMISE.ows", "9.15.0 THE PROMISE"),
    ("9.16.0 - THE VISITOR.ows", "9.16.0 THE VISITOR"),
    ("9.17.0 - TIME TO LEAVE.ows", "9.17.0 TIME TO LEAVE"),
    ("9.18.0 - WALTZ.ows", "9.18.0 WALTZ"),
    ("9.19.0 - CUT - AFTER THE DEFECTION.ows", "9.19.0 CUT - AFTER THE DEFECTION"),
    ("9.20.0 - CUT - MARK LOGS THE DEFECTION.ows", "9.20.0 CUT - MARK LOGS THE DEFECTION"),
    ("9.21.0 - ALT - THEY CAN'T MOVE.ows", "9.21.0 ALT - THEY CAN'T MOVE"),
]

PENDING_DOWNLOADS = [
    {
        "song": "8.03.0 - LUKE AND AMIRA.ows",
        "base_title": "8.03.0 LUKE AND AMIRA",
        "title": "8.03.0 LUKE AND AMIRA v002",
        "song_ids": ["311e3911-69d8-41b8-a63e-0369e6106312", "970f9c41-b1ab-45dd-9550-9ec092c6ca90"],
    }
]


def ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def log_event(event: dict):
    event["ts"] = ts()
    line = json.dumps(event, ensure_ascii=False)
    print(f"[LOG] {line}", flush=True)
    with open(JSONL_LOG, "a") as f:
        f.write(line + "\n")
        f.flush()


def curl_mcp(tool_name: str, arguments: dict) -> dict:
    """Call MCP via curl subprocess."""
    payload = json.dumps({"name": tool_name, "arguments": arguments})
    url = f"{MCP_BASE}/{tool_name}"
    result = subprocess.run(
        ["curl", "-s", "--max-time", "120", "-X", "POST", url,
         "-H", "Content-Type: application/json",
         "-d", payload],
        capture_output=True, text=True, timeout=130
    )
    if result.returncode != 0:
        return {"success": False, "result": f"curl error: {result.stderr}"}
    try:
        return json.loads(result.stdout)
    except Exception as e:
        return {"success": False, "result": f"JSON parse error: {e} raw={result.stdout[:200]}"}


def get_cover_status(song_id: str) -> str:
    resp = curl_mcp("suno_get_cover_status", {"song_id": song_id})
    return resp.get("result", "")


def download_cover(song_id: str, download_path: str) -> str:
    resp = curl_mcp("suno_download_cover", {"song_id": song_id, "download_path": download_path})
    return resp.get("result", "")


def create_cover(file_path: str, title: str) -> dict:
    return curl_mcp("suno_create_cover", {
        "file_path": file_path,
        "style": COVER_STYLE,
        "lyrics": COVER_LYRICS,
        "exclude_styles": COVER_EXCLUDE,
        "weirdness": 0,
        "style_influence": 30,
        "audio_influence": 95,
        "vocal_gender": "",
        "title": title,
    })


def wait_and_download_cover(song_ids: list, download_path: str, song_name: str, title: str) -> bool:
    os.makedirs(download_path, exist_ok=True)
    remaining = list(song_ids)
    max_wait = 600
    poll_interval = 30
    elapsed = 0

    while remaining and elapsed < max_wait:
        print(f"  Polling {len(remaining)} IDs (elapsed {elapsed}s)...", flush=True)
        still_pending = []
        for sid in remaining:
            result = get_cover_status(sid)
            print(f"  Status {sid[:8]}: {result[:80]}", flush=True)
            if "status=complete" in result:
                dl_result = download_cover(sid, download_path)
                print(f"  Download: {dl_result[:100]}", flush=True)
                if "Downloaded WAV" in dl_result:
                    log_event({"event": "download_ok", "song": song_name, "song_id": sid, "result": dl_result})
                else:
                    log_event({"event": "download_error", "song": song_name, "song_id": sid, "result": dl_result})
                    still_pending.append(sid)  # retry
            elif "status=not_found" in result:
                log_event({"event": "download_not_found", "song": song_name, "song_id": sid})
                print(f"  WARNING: {sid} not found", flush=True)
                # Don't retry not_found
            else:
                still_pending.append(sid)

        remaining = still_pending
        if remaining:
            print(f"  {len(remaining)} still pending, sleeping {poll_interval}s...", flush=True)
            time.sleep(poll_interval)
            elapsed += poll_interval

    if remaining:
        log_event({"event": "download_timeout", "song": song_name, "song_ids": remaining})
        print(f"  WARNING: Timed out waiting for {remaining}", flush=True)
        return False
    return True


def export_wav(song_file: str, upload_path: str) -> bool:
    os.makedirs(os.path.dirname(upload_path), exist_ok=True)
    env = os.environ.copy()
    env["NOVOTRO_ALLOW_BLUETOOTH_OUTPUT"] = "1"
    env["NOVOTRO_SCORE_BIN"] = NOVOTRO_SCORE_BIN
    song_path = f"Songs/{song_file}"

    for attempt in range(1, 4):
        print(f"  Export attempt {attempt}/3: {song_file}", flush=True)
        if os.path.exists(upload_path):
            os.remove(upload_path)

        try:
            result = subprocess.run(
                [EXPORT_SCRIPT, "--project", PROJECT_DIR, "--song-path", song_path, "--output", upload_path],
                env=env,
                timeout=900,
            )
        except subprocess.TimeoutExpired:
            log_event({"event": "export_error", "song": song_file, "attempt": attempt, "rc": "timeout"})
            print(f"  Export timed out", flush=True)
            if attempt < 3:
                time.sleep(5)
            continue

        if result.returncode == 0 and os.path.exists(upload_path) and os.path.getsize(upload_path) > 1_000_000:
            size = os.path.getsize(upload_path)
            log_event({"event": "export_ok", "song": song_file, "path": upload_path, "size": size})
            print(f"  Export OK: {size // 1024 // 1024} MB", flush=True)
            return True
        elif result.returncode == 133:
            log_event({"event": "export_retry", "song": song_file, "attempt": attempt, "attempts": 3, "rc": 133, "reason": "sigtrap"})
            print(f"  Export rc=133 (SIGTRAP), retrying...", flush=True)
            time.sleep(5)
        else:
            log_event({"event": "export_error", "song": song_file, "attempt": attempt, "rc": result.returncode})
            print(f"  Export failed with rc={result.returncode}", flush=True)
            if attempt < 3:
                time.sleep(5)

    return False


def get_next_version(preview_dir: str) -> str:
    if not os.path.exists(preview_dir):
        return "v002"
    files = os.listdir(preview_dir)
    versions = []
    for f in files:
        for i in range(1, 100):
            vtag = f"v{i:03d}"
            if vtag in f and "Upload" not in f:
                versions.append(i)
    if not versions:
        return "v002"
    return f"v{max(versions) + 1:03d}"


def process_song(song_file: str, base_title: str):
    print(f"\n{'='*60}", flush=True)
    print(f"Processing: {base_title}", flush=True)
    print(f"{'='*60}", flush=True)

    preview_dir = f"{PREVIEWS_DIR}/{base_title}"
    upload_path = f"{preview_dir}/{base_title} v001-Upload.wav"

    log_event({"event": "song_start", "song": song_file, "base_title": base_title, "upload": upload_path})

    # Step 1: Export if needed
    if os.path.exists(upload_path) and os.path.getsize(upload_path) > 1_000_000:
        print(f"  Upload WAV exists ({os.path.getsize(upload_path) // 1024 // 1024} MB), skipping export", flush=True)
    else:
        print(f"  Exporting {song_file}...", flush=True)
        if not export_wav(song_file, upload_path):
            log_event({"event": "song_error", "song": song_file, "stage": "export", "reason": "export_failed_after_retries"})
            return False

    # Step 2: Determine cover version
    cover_version = get_next_version(preview_dir)
    cover_title = f"{base_title} {cover_version}"
    print(f"  Submitting cover: {cover_title}", flush=True)

    # Step 3: Create cover
    resp = create_cover(upload_path, cover_title)
    result_text = resp.get("result", "")
    print(f"  Cover result: {result_text[:200]}", flush=True)

    if "CAPTCHA" in result_text or "captcha" in result_text.lower():
        log_event({"event": "song_error", "song": song_file, "stage": "create_cover_captcha", "result": result_text})
        print(f"  CAPTCHA required - skipping {base_title}", flush=True)
        return "captcha"

    if not resp.get("success") or "Song IDs:" not in result_text:
        log_event({"event": "song_error", "song": song_file, "stage": "create_cover", "result": result_text})
        print(f"  Cover creation failed - skipping", flush=True)
        return False

    # Parse song IDs
    try:
        ids_part = result_text.split("Song IDs:")[1].strip().split("\n")[0].strip()
        song_ids = ast.literal_eval(ids_part)
    except Exception as e:
        log_event({"event": "song_error", "song": song_file, "stage": "parse_ids", "result": result_text, "error": str(e)})
        print(f"  Failed to parse song IDs: {e}", flush=True)
        return False

    log_event({"event": "cover_ids", "song": song_file, "title": cover_title, "song_ids": song_ids})
    print(f"  Song IDs: {song_ids}", flush=True)

    # Step 4: Wait and download
    success = wait_and_download_cover(song_ids, preview_dir, song_file, cover_title)
    if success:
        log_event({"event": "song_done", "song": song_file, "title": cover_title, "song_ids": song_ids})
        print(f"  Done: {cover_title}", flush=True)
    return success


def main():
    print("=== Amira Suno Cover Runner - Remaining Songs ===", flush=True)
    print(f"Songs to process: {len(REMAINING_SONGS)}", flush=True)

    # Handle pending downloads first (8.03.0 LUKE AND AMIRA)
    print("\n--- Handling pending downloads ---", flush=True)
    for pending in PENDING_DOWNLOADS:
        preview_dir = f"{PREVIEWS_DIR}/{pending['base_title']}"
        print(f"\nDownloading: {pending['title']}", flush=True)
        success = wait_and_download_cover(
            pending["song_ids"],
            preview_dir,
            pending["song"],
            pending["title"]
        )
        if success:
            log_event({
                "event": "song_done",
                "song": pending["song"],
                "title": pending["title"],
                "song_ids": pending["song_ids"]
            })

    # Process remaining songs
    print("\n--- Processing remaining songs ---", flush=True)
    captcha_count = 0
    success_count = 0
    error_count = 0

    for song_file, base_title in REMAINING_SONGS:
        result = process_song(song_file, base_title)
        if result == "captcha":
            captcha_count += 1
            if captcha_count >= 3:
                print("\nToo many CAPTCHA blocks - stopping.", flush=True)
                break
        elif result:
            success_count += 1
        else:
            error_count += 1

    print(f"\n=== Complete ===", flush=True)
    print(f"Success: {success_count}, Errors: {error_count}, CAPTCHA: {captcha_count}", flush=True)
    log_event({
        "event": "batch_complete",
        "success": success_count,
        "errors": error_count,
        "captcha_blocks": captcha_count
    })


if __name__ == "__main__":
    main()
