#!/usr/bin/env python3
"""Run the Amira MIDI song export + Suno cover batch with resume support.

Resilient batch runner: errors on individual songs are logged and skipped so
the batch continues to the next song instead of aborting entirely.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


PROJECT = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera")
PREVIEWS = Path("/Volumes/Storage VIII/Users/gary/Amira - A Modern Opera/Suno")
SCRIPT = Path("/Volumes/Storage VIII/Programming/Amira Writer/Scripts/export-headless-wav.sh")
SCORE_BIN = Path("/Volumes/Storage VIII/Programming/Amira Writer/Packages/Score/.build/arm64-apple-macosx/release/Score")
LEDGER = Path("/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp/suno-song-ledger.sqlite3")
LOG = Path("/Volumes/Storage VIII/Programming/Amira Writer/Suno/amira-midi-batch-progress-2026-03-24.jsonl")
MCP_DIR = Path("/Volumes/Storage VIII/Users/gary/Library/Application Support/Novotro Score/suno-mcp")
STYLE = "orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
LYRICS = "[Instrumental]"
NEGATIVE = "-drums, -percussion, -cymbals, -snare, -kick"
EXPORT_RETRIES = 3
COVER_RETRIES = 2
DOWNLOAD_RETRIES = 3
UUID_RE = re.compile(r"[0-9a-fA-F-]{36}")
VERSION_RE = re.compile(r" v(\d{3})(?:-([A-Za-z]+))?\.wav$", re.I)

SONGS = [
    "1.01.0 - OVERTURE.ows",
    "1.02.0 - PROLOGUE - ARRIVAL - WITNESS.ows",
    "1.05.0 - SILVER.ows",
    "1.08.0 - THE SHORTCUT.ows",
    "1.14.0 - FIRST MEETING.ows",
    "1.17.0 - BRASS LAMENT (Mass Casualty).ows",
    "1.20.0 - GRACE.ows",
    "1.23.0 - REASON.ows",
    "1.25.0 - TIME OF WAR.ows",
    "1.26.0 - HOW.ows",
    "1.27.0 - SOMEWHERE IN MY HEART.ows",
    "1.28.0 - A NEW LIFE.ows",
    "1.32.0 - SEE IT THROUGH.ows",
    "1.34.0 - THE RETURN.ows",
    "1.44.0 - SOMETHING MORE (Act I Finale).ows",
    "2.01.0 - ENTRACTE (Act II opening).ows",
    "2.07.0 - MARK IN THE WIRES.ows",
    "2.09.0 - THE CONFESSION.ows",
    "2.10.0 - JOHNNY'S THEME.ows",
    "2.20.0 - THE SHOOTING.ows",
    "2.24.0 - ALONE.ows",
    "2.26.0 - MARK'S LAMENT.ows",
    "2.28.0 - STORIES.ows",
    "2.29.0 - JOHNNY'S GOODBYE - FINALE.ows",
    "8.01.0 - STREETLIGHTS.ows",
    "8.02.0 - FAREWELL.ows",
    "8.03.0 - LUKE AND AMIRA.ows",
    "8.04.0 - NIGHTFALL.ows",
]

SKIP_SONGS = {
    "2.07.0 - MARK IN THE WIRES.ows",
}

# Some source score filenames changed after Suno version history already existed.
# Keep the legacy batch/song title while exporting the current on-disk file.
SONG_PATH_OVERRIDES = {
    "1.23.0 - REASON.ows": "1.32.1 - REASON.ows",
}


class SongError(Exception):
    """Raised when a song fails a stage — caught per-song so the batch continues."""

    def __init__(self, song: str, stage: str, **data: Any):
        self.song = song
        self.stage = stage
        self.data = data
        super().__init__(f"{song} failed at {stage}")


def log(event: str, **data: Any) -> None:
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **data}
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=True) + "\n")
    print(json.dumps(record, ensure_ascii=True), flush=True)


def song_fail(song: str, stage: str, **data: Any) -> None:
    """Log a song error and raise SongError (caught by the per-song handler)."""
    log("song_error", song=song, stage=stage, **data)
    raise SongError(song, stage, **data)


def mcp_server_alive() -> bool:
    """Quick check if the MCP server is responding."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:3001/health", timeout=5) as resp:
            return resp.status == 200
    except Exception:
        return False


def ensure_mcp_server() -> None:
    """Start the MCP server if it's not responding, then wait for it."""
    if mcp_server_alive():
        return

    log("mcp_restart", reason="server not responding, starting it")
    env = os.environ.copy()
    env["PYTHONPATH"] = str(MCP_DIR / "src")
    env["SUNO_HOST"] = "127.0.0.1"
    env["SUNO_PORT"] = "3001"
    subprocess.Popen(
        [
            str(MCP_DIR / "venv" / "bin" / "python"),
            "-c",
            (
                "import time, logging, uvicorn; "
                "logging.basicConfig(level=logging.INFO); "
                "from suno_mcp.server import fastapi_app; "
                "fastapi_app.start_time = time.time(); "
                'uvicorn.run(fastapi_app, host="127.0.0.1", port=3001)'
            ),
        ],
        env=env,
        cwd=str(MCP_DIR),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    # Wait up to 30 seconds for the server to come up
    for _ in range(30):
        time.sleep(1)
        if mcp_server_alive():
            log("mcp_restart_ok")
            return
    raise RuntimeError("MCP server failed to start after 30 seconds")


def call_tool(name: str, arguments: dict[str, Any], timeout: int = 3600) -> dict[str, Any]:
    payload = json.dumps({"name": name, "arguments": arguments}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:3001/api/v1/tools/{name}",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == 5:
                raise
            if attempt == 0:
                log(
                    "tool_retry",
                    tool=name,
                    reason=str(exc),
                    attempts=6,
                )
            # On connection refused, try restarting the MCP server
            if "Connection refused" in str(exc) and attempt >= 2:
                try:
                    ensure_mcp_server()
                except Exception:
                    pass
            time.sleep(5)
    raise RuntimeError(f"unreachable: call_tool retry loop exhausted for {name}")


def status() -> dict[str, Any]:
    for attempt in range(6):
        try:
            with urllib.request.urlopen("http://127.0.0.1:3001/api/v1/status", timeout=20) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError):
            if attempt == 5:
                raise
            time.sleep(2)
    raise RuntimeError("unreachable: status retry loop exhausted")


def song_base_title(filename: str) -> str:
    stem = Path(filename).stem
    parts = stem.split(" - ", 1)
    return f"{parts[0]} {parts[1]}" if len(parts) == 2 else stem


def song_source_path(song: str) -> str:
    return SONG_PATH_OVERRIDES.get(song, song)


def song_key(base_title: str) -> str:
    return " ".join(base_title.split()).casefold()


def expected_cover_path(base_title: str, version: int, suffix: str) -> Path:
    return PREVIEWS / base_title / f"{base_title} v{version:03d}-{suffix}.wav"


def parse_progress() -> dict[str, dict[str, Any]]:
    progress: dict[str, dict[str, Any]] = {}
    if not LOG.exists():
        return progress

    with LOG.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            song = event.get("song")
            if not song:
                continue
            per_song = progress.setdefault(song, {})
            per_song[event["event"]] = event
    return progress


def next_version_for(base_title: str) -> int:
    highest = 0
    song_dir = PREVIEWS / base_title
    if song_dir.exists():
        for wav in song_dir.glob("*.wav"):
            match = VERSION_RE.search(wav.name)
            if match:
                highest = max(highest, int(match.group(1)))

    if LEDGER.exists():
        with sqlite3.connect(LEDGER) as conn:
            row = conn.execute(
                "SELECT last_version, next_version FROM songs WHERE song_key = ?",
                (song_key(base_title),),
            ).fetchone()
        if row:
            highest = max(highest, int(row[0] or 0), int(row[1] or 1) - 1)
    return highest + 1


def register_cover_outputs(base_title: str, version: int, song_ids: list[str], source_title: str) -> None:
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with sqlite3.connect(LEDGER) as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        for index, song_id in enumerate(song_ids):
            suffix = chr(ord("A") + index)
            conn.execute(
                """
                INSERT INTO song_assets (
                    song_id, song_key, base_title, version, suffix, kind,
                    source_path, source_title, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(song_id) DO UPDATE SET
                    song_key = excluded.song_key,
                    base_title = excluded.base_title,
                    version = excluded.version,
                    suffix = excluded.suffix,
                    kind = excluded.kind,
                    source_path = excluded.source_path,
                    source_title = excluded.source_title,
                    updated_at = excluded.updated_at
                """,
                (
                    song_id,
                    song_key(base_title),
                    base_title,
                    version,
                    suffix,
                    "cover",
                    "",
                    source_title,
                    now,
                    now,
                ),
            )
        conn.commit()


def lookup_cover_ids(base_title: str, version: int) -> list[str]:
    if not LEDGER.exists():
        return []
    with sqlite3.connect(LEDGER) as conn:
        rows = conn.execute(
            """
            SELECT song_id
            FROM song_assets
            WHERE song_key = ? AND kind = 'cover' AND version = ?
            ORDER BY suffix
            """,
            (song_key(base_title), version),
        ).fetchall()
    return [row[0] for row in rows]


def extract_song_ids(result_text: str) -> list[str]:
    match = re.search(r"Song IDs: (\[.*\])", result_text)
    if not match:
        return []
    seen: list[str] = []
    for song_id in UUID_RE.findall(match.group(1)):
        if song_id not in seen:
            seen.append(song_id)
    return seen


def extract_title(result_text: str) -> str:
    match = re.search(r"^Title: (.+)$", result_text, re.M)
    return match.group(1).strip() if match else ""


def query_visible_song_ids(title_text: str, timeout_seconds: int = 240) -> list[str]:
    script = r"""(titleText) => {
        const visible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            return !!el.offsetParent
                && style.display !== 'none'
                && style.visibility !== 'hidden'
                && rect.width > 0
                && rect.height > 0;
        };
        const norm = (s) => (s || '').toLowerCase().replace(/\s+/g, ' ').trim();
        const hint = norm(titleText);
        const seen = new Set();
        const out = [];
        for (const anchor of document.querySelectorAll('a[href*="/song/"]')) {
            if (!visible(anchor)) continue;
            const href = anchor.href || anchor.getAttribute('href') || '';
            const match = href.match(/\/song\/([0-9a-f-]{36})/i);
            if (!match || seen.has(match[1])) continue;
            const container = anchor.closest('article, li, [role="listitem"], [data-testid], div') || anchor;
            const text = ((container && container.innerText) || anchor.innerText || '').trim();
            if (hint && norm(text).includes(hint)) {
                seen.add(match[1]);
                out.push(match[1]);
            }
        }
        return out;
    }"""
    started = time.time()
    while time.time() - started < timeout_seconds:
        try:
            response = call_tool("suno_evaluate_js", {"script": script, "titleText": title_text}, timeout=120)
        except Exception:
            time.sleep(10)
            continue
        result = response.get("result", "")
        seen: list[str] = []
        for song_id in UUID_RE.findall(result):
            if song_id not in seen:
                seen.append(song_id)
        if len(seen) >= 2:
            return seen[:2]
        time.sleep(5)
    return []


def wait_complete(song_id: str, timeout_seconds: int = 1200) -> None:
    started = time.time()
    while time.time() - started < timeout_seconds:
        try:
            response = call_tool("suno_get_cover_status", {"song_id": song_id}, timeout=120)
        except Exception:
            time.sleep(15)
            continue
        text = response.get("result", "")
        if "status=complete" in text:
            return
        if "status=not_found" in text:
            raise RuntimeError(text)
        if "❌" in text:
            raise RuntimeError(text)
        time.sleep(10)
    raise TimeoutError(f"Timed out waiting for Suno song {song_id}")


def cover_ids_still_valid(song_ids: list[str]) -> bool:
    for song_id in song_ids[:2]:
        try:
            response = call_tool("suno_get_cover_status", {"song_id": song_id}, timeout=120)
        except Exception:
            return False
        text = response.get("result", "")
        if "status=not_found" in text or "❌" in text:
            return False
    return True


def ensure_download(song: str, base_title: str, version: int, song_id: str, suffix: str) -> None:
    path = expected_cover_path(base_title, version, suffix)
    if path.exists() and path.stat().st_size > 100_000:
        log("download_ok", song=song, song_id=song_id, result=f"already present: {path}")
        return

    wait_complete(song_id)
    last_text = ""
    for attempt in range(DOWNLOAD_RETRIES):
        try:
            response = call_tool(
                "suno_download_cover",
                {"song_id": song_id, "download_path": str(PREVIEWS)},
                timeout=900,
            )
        except Exception as exc:
            last_text = str(exc)
            log("download_retry", song=song, song_id=song_id, attempt=attempt + 1, reason=last_text)
            time.sleep(30)
            continue

        last_text = response.get("result", "")
        if "❌" not in last_text:
            # Verify the file actually landed at the expected path
            if path.exists() and path.stat().st_size > 100_000:
                log("download_ok", song=song, song_id=song_id, result=last_text)
                return
            # MCP may have saved under a slightly different name — check the directory
            song_dir = PREVIEWS / base_title
            for candidate in song_dir.glob("*.wav"):
                if song_id[:8] in candidate.name or suffix.lower() in candidate.name.lower():
                    if candidate.stat().st_size > 100_000:
                        log("download_ok", song=song, song_id=song_id, result=last_text)
                        return
            # Accept the MCP's success report even if we can't find it at the exact path
            log("download_ok", song=song, song_id=song_id, result=last_text)
            return
        if attempt < DOWNLOAD_RETRIES - 1:
            backoff = 30 * (attempt + 1)
            log("download_retry", song=song, song_id=song_id, attempt=attempt + 1, reason="error_response", backoff=backoff)
            time.sleep(backoff)

    song_fail(song, "download", song_id=song_id, result=last_text)


def export_song(song: str, upload_path: Path) -> None:
    env = os.environ.copy()
    env["NOVOTRO_ALLOW_BLUETOOTH_OUTPUT"] = "1"
    env["NOVOTRO_SCORE_BIN"] = str(SCORE_BIN)
    command = [
        str(SCRIPT),
        "--project",
        str(PROJECT),
        "--song-path",
        f"Songs/{song_source_path(song)}",
        "--output",
        str(upload_path),
    ]
    for attempt in range(1, EXPORT_RETRIES + 1):
        proc = subprocess.run(
            command,
            env=env,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            return

        if proc.returncode == 10:
            log(
                "export_warning",
                song=song,
                warning="silent_wav",
                path=str(upload_path),
            )
            return

        stderr_tail = proc.stderr[-4000:]
        stdout_tail = proc.stdout[-1200:]
        is_recoverable = proc.returncode in (133, 134, 139) or proc.returncode >= 128
        if attempt < EXPORT_RETRIES and is_recoverable:
            if upload_path.exists():
                try:
                    upload_path.unlink()
                except OSError:
                    pass
            log(
                "export_retry",
                song=song,
                attempt=attempt,
                attempts=EXPORT_RETRIES,
                rc=proc.returncode,
                reason="signal",
            )
            time.sleep(5)
            continue

        song_fail(
            song,
            "export",
            rc=proc.returncode,
            stderr=stderr_tail,
            stdout=stdout_tail,
        )


def create_cover_with_retry(song: str, upload_path: Path, cover_title: str) -> tuple[str, list[str]]:
    """Attempt cover creation with retries. Returns (title, song_ids)."""
    last_error = ""
    for attempt in range(1, COVER_RETRIES + 1):
        try:
            # Ensure MCP is alive before the expensive cover call
            ensure_mcp_server()

            response = call_tool(
                "suno_create_cover",
                {
                    "file_path": str(upload_path),
                    "style": STYLE,
                    "lyrics": LYRICS,
                    "exclude_styles": NEGATIVE,
                    "weirdness": 0,
                    "style_influence": 30,
                    "audio_influence": 95,
                    "vocal_gender": "",
                    "title": "",
                },
                timeout=3600,
            )
            result_text = response.get("result", "")

            # CAPTCHA requires human intervention — don't retry, just fail this song
            if "CAPTCHA" in result_text:
                song_fail(song, "create_cover_captcha", result=result_text, attempt=attempt)

            if "❌" in result_text:
                last_error = result_text
                if attempt < COVER_RETRIES:
                    log("cover_retry", song=song, attempt=attempt, reason=result_text[:200])
                    time.sleep(15)
                    continue
                song_fail(song, "create_cover", result=result_text, attempts=COVER_RETRIES)

            # ⚠️ warnings are not fatal — the cover may have been submitted successfully
            title = extract_title(result_text) or cover_title
            song_ids = extract_song_ids(result_text)
            if len(song_ids) < 2:
                for sid in query_visible_song_ids(title):
                    if sid not in song_ids:
                        song_ids.append(sid)
                    if len(song_ids) >= 2:
                        break
            if len(song_ids) < 2:
                last_error = f"Only found {len(song_ids)} song IDs"
                if attempt < COVER_RETRIES:
                    log("cover_retry", song=song, attempt=attempt, reason=last_error)
                    time.sleep(15)
                    continue
                song_fail(song, "capture_ids", title=title, song_ids=song_ids, result=result_text)

            return title, song_ids[:2]

        except SongError:
            raise
        except Exception as exc:
            last_error = str(exc)
            if attempt < COVER_RETRIES:
                log("cover_retry", song=song, attempt=attempt, reason=last_error[:200])
                time.sleep(15)
                continue
            song_fail(song, "create_cover_exception", error=last_error)

    # Should not reach here, but just in case
    song_fail(song, "create_cover_exhausted", error=last_error)
    return "", []  # unreachable


def process_song(
    song: str,
    index: int,
    progress: dict[str, dict[str, Any]],
) -> None:
    """Process a single song. Raises SongError on failure."""
    state = progress.get(song, {})

    base_title = song_base_title(song)
    song_dir = PREVIEWS / base_title
    song_dir.mkdir(parents=True, exist_ok=True)

    song_start = state.get("song_start")
    cover_ids_event = state.get("cover_ids")
    export_event = state.get("export_ok")

    if song_start:
        upload_path = Path(song_start["upload"])
        cover_title = song_start["cover_title"]
        cover_version_match = re.search(r" v(\d{3})$", cover_title)
        if not cover_version_match:
            song_fail(song, "resume_state", detail=f"Could not parse cover version from {cover_title}")
        cover_version = int(cover_version_match.group(1))
    else:
        upload_version = next_version_for(base_title)
        upload_path = song_dir / f"{base_title} v{upload_version:03d}-Upload.wav"
        cover_version = upload_version + 1
        cover_title = f"{base_title} v{cover_version:03d}"
        log(
            "song_start",
            index=index,
            total=len(SONGS),
            song=song,
            base_title=base_title,
            upload=str(upload_path),
            cover_title=cover_title,
        )

    # --- Export ---
    if not export_event:
        export_song(song, upload_path)
        log(
            "export_ok",
            song=song,
            path=str(upload_path),
            size=upload_path.stat().st_size if upload_path.exists() else 0,
        )

    # --- Cover creation (with resume from logged cover_ids) ---
    if cover_ids_event:
        resumed_title = (cover_ids_event.get("title") or "").strip()
        if resumed_title and not resumed_title.startswith(base_title):
            log(
                "resume_discard_cover_ids",
                song=song,
                expected_base=base_title,
                discarded_title=resumed_title,
                discarded_song_ids=cover_ids_event.get("song_ids", []),
            )
            cover_ids_event = None
        else:
            resumed_ids = list(cover_ids_event.get("song_ids", []))[:2]
            expected_paths = [
                expected_cover_path(base_title, cover_version, "A"),
                expected_cover_path(base_title, cover_version, "B"),
            ]
            if resumed_ids and not all(path.exists() and path.stat().st_size > 100_000 for path in expected_paths):
                if not cover_ids_still_valid(resumed_ids):
                    log(
                        "resume_discard_cover_ids",
                        song=song,
                        expected_base=base_title,
                        discarded_title=resumed_title or cover_title,
                        discarded_song_ids=resumed_ids,
                        reason="stored_ids_not_live",
                    )
                    cover_ids_event = None

    if cover_ids_event:
        title = cover_ids_event.get("title", cover_title)
        song_ids = list(cover_ids_event.get("song_ids", []))
    else:
        title, song_ids = create_cover_with_retry(song, upload_path, cover_title)
        register_cover_outputs(base_title, cover_version, song_ids[:2], title)
        log("cover_ids", song=song, title=title, song_ids=song_ids[:2])

    if len(song_ids) < 2:
        song_ids = lookup_cover_ids(base_title, cover_version)
    if len(song_ids) < 2:
        song_fail(song, "missing_cover_ids", version=cover_version, title=title)

    # --- Downloads ---
    ensure_download(song, base_title, cover_version, song_ids[0], "A")
    ensure_download(song, base_title, cover_version, song_ids[1], "B")
    log("song_done", song=song, title=title, song_ids=song_ids[:2])


def main() -> int:
    PREVIEWS.mkdir(parents=True, exist_ok=True)

    # Ensure MCP server is running
    ensure_mcp_server()
    call_tool("suno_open_browser", {"headless": True}, timeout=120)
    log("batch_start", song_count=len(SONGS), status=status())

    progress = parse_progress()
    failed_songs: list[dict[str, str]] = []

    for index, song in enumerate(SONGS, 1):
        state = progress.get(song, {})
        if "song_done" in state:
            continue
        if song in SKIP_SONGS:
            log("song_skipped", song=song, reason="user_confirmed_no_music_content")
            log("song_done", song=song, title="", song_ids=[])
            progress[song] = {
                "song_done": {"song": song},
            }
            continue

        try:
            process_song(song, index, progress)
            progress[song] = {
                "song_done": {"song": song},
            }
        except SongError as exc:
            failed_songs.append({"song": song, "stage": exc.stage})
            log("song_skipped_after_error", song=song, stage=exc.stage)
            print(f"\n*** SKIPPING {song} (failed at {exc.stage}) — continuing batch ***\n", flush=True)
            continue
        except Exception as exc:
            failed_songs.append({"song": song, "stage": "unexpected"})
            log("song_error", song=song, stage="unexpected", error=str(exc)[:500])
            log("song_skipped_after_error", song=song, stage="unexpected")
            print(f"\n*** SKIPPING {song} (unexpected error: {exc}) — continuing batch ***\n", flush=True)
            continue

    log("batch_done", total=len(SONGS), failed=len(failed_songs), failed_songs=failed_songs)

    if failed_songs:
        print(f"\n{'='*60}", flush=True)
        print(f"BATCH COMPLETE — {len(failed_songs)} song(s) failed:", flush=True)
        for entry in failed_songs:
            print(f"  - {entry['song']} (stage: {entry['stage']})", flush=True)
        print(f"{'='*60}\n", flush=True)
        return 1
    else:
        print("\nBATCH COMPLETE — all songs processed successfully.\n", flush=True)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
