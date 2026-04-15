#!/usr/bin/env python3
"""RunPod stale-pod watchdog for Amira Writer.

This daemon watches the heartbeat file written by `RunPodLORAService` at
`$TMPDIR/amira-runpod-watchdog.json`. If the heartbeat goes stale, it
terminates the pod via RunPod GraphQL so paid GPU time does not keep burning
after Amira Writer crashes or disconnects.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
TMP_DIR = Path(tempfile.gettempdir())
LEGACY_WATCHDOG_PATH = TMP_DIR / "amira-runpod-watchdog.json"
WATCHDOG_DIR = TMP_DIR / "amira-runpod-watchdogs"
PID_PATH = TMP_DIR / "amira-runpod_pod_monitor.pid"
LOG_DIR = Path.home() / "Library/Logs/Amira"
LOG_PATH = LOG_DIR / "runpod_pod_monitor.log"

GRAPHQL_URL = "https://api.runpod.io/graphql"
POLL_SECONDS = 30
STALE_SECONDS = 180
KEYCHAIN_SERVICE = "com.amira.writer.animate"
KEYCHAIN_ACCOUNT = "runpod-api-key"


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = now_utc().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    line = f"[{stamp}] {message}\n"
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(line)
    print(message)


def read_text(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None
    return text or None


def load_api_key() -> str:
    env = os.environ.get("RUNPOD_API_KEY", "").strip()
    if env:
        return env

    file_value = read_text(Path.home() / ".lora-maker/runpod_api_key")
    if file_value:
        return file_value

    try:
        output = subprocess.check_output(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if output:
            return output
    except Exception:
        pass

    raise RuntimeError(
        "RunPod API key not found in RUNPOD_API_KEY, ~/.lora-maker/runpod_api_key, or Keychain."
    )


def graphql_request(query: str) -> dict[str, Any]:
    api_key = load_api_key()
    payload = json.dumps({"query": query}).encode("utf-8")
    request = urllib.request.Request(
        GRAPHQL_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"RunPod HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"RunPod request failed: {exc}") from exc

    result = json.loads(data.decode("utf-8"))
    if result.get("errors"):
        raise RuntimeError(f"RunPod GraphQL errors: {result['errors']}")
    return result


def terminate_pod(pod_id: str, reason: str) -> None:
    query = f'mutation {{ podTerminate(input: {{ podId: "{pod_id}" }}) }}'
    graphql_request(query)
    log(f"Terminated pod {pod_id} ({reason})")


def watchdog_files() -> list[Path]:
    files: list[Path] = []
    if LEGACY_WATCHDOG_PATH.exists():
        files.append(LEGACY_WATCHDOG_PATH)
    if WATCHDOG_DIR.exists():
        files.extend(sorted(WATCHDOG_DIR.glob("*.json")))
    return files


def load_watchdog_state(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        log(f"Invalid watchdog JSON at {path}: {exc}")
        return None

    if not isinstance(data, dict):
        log(f"Unexpected watchdog payload type at {path}: {type(data).__name__}")
        return None
    return data


def parse_timestamp(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return dt.datetime.fromisoformat(value).astimezone(dt.timezone.utc)
    except ValueError:
        return None


def heartbeat_snapshots() -> list[dict[str, Any]]:
    snapshots: list[dict[str, Any]] = []
    for path in watchdog_files():
        state = load_watchdog_state(path)
        if not state:
            continue

        pod_id = state.get("podID")
        pid = state.get("pid")
        timestamp = parse_timestamp(state.get("timestamp"))
        feature = state.get("feature") if isinstance(state.get("feature"), str) else "legacy"
        if not isinstance(pod_id, str) or not pod_id:
            continue

        age = None if timestamp is None else max(0.0, (now_utc() - timestamp).total_seconds())
        snapshots.append(
            {
                "path": path,
                "feature": feature,
                "pod_id": pod_id,
                "age": age,
                "owner_pid": pid if isinstance(pid, int) else None,
            }
        )
    return snapshots


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def read_monitor_pid() -> int | None:
    text = read_text(PID_PATH)
    if not text:
        return None
    try:
        pid = int(text)
    except ValueError:
        return None
    return pid if pid_is_alive(pid) else None


def write_monitor_pid() -> None:
    PID_PATH.write_text(str(os.getpid()), encoding="utf-8")


def clear_monitor_pid() -> None:
    try:
        PID_PATH.unlink()
    except FileNotFoundError:
        pass


def monitor_loop() -> int:
    write_monitor_pid()
    log(f"RunPod monitor started (poll={POLL_SECONDS}s, stale={STALE_SECONDS}s)")

    def _handle_exit(signum: int, _frame: Any) -> None:
        log(f"RunPod monitor stopping on signal {signum}")
        clear_monitor_pid()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _handle_exit)
    signal.signal(signal.SIGINT, _handle_exit)

    try:
        while True:
            for snapshot in heartbeat_snapshots():
                age = snapshot["age"]
                if age is None or age <= STALE_SECONDS:
                    continue

                pod_id = snapshot["pod_id"]
                owner_pid = snapshot["owner_pid"]
                feature = snapshot["feature"]
                path = snapshot["path"]
                reason = f"stale heartbeat feature={feature} age={int(age)}s owner_pid={owner_pid}"
                try:
                    terminate_pod(pod_id, reason)
                except Exception as exc:
                    log(f"Failed to terminate stale pod {pod_id} from {path}: {exc}")
                else:
                    try:
                        path.unlink()
                    except FileNotFoundError:
                        pass
            time.sleep(POLL_SECONDS)
    finally:
        clear_monitor_pid()


def ensure_monitor() -> int:
    existing_pid = read_monitor_pid()
    if existing_pid:
        print(f"RunPod monitor already running (pid {existing_pid})")
        return 0

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        proc = subprocess.Popen(
            [sys.executable, str(SCRIPT_PATH), "run"],
            stdin=subprocess.DEVNULL,
            stdout=handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    print(f"Started RunPod monitor (pid {proc.pid})")
    return 0


def status() -> int:
    monitor_pid = read_monitor_pid()
    if monitor_pid:
        print(f"monitor: running (pid {monitor_pid})")
    else:
        print("monitor: stopped")

    snapshots = heartbeat_snapshots()
    if snapshots:
        for snapshot in snapshots:
            age = snapshot["age"]
            age_text = "unknown" if age is None else f"{int(age)}s"
            stale = age is not None and age > STALE_SECONDS
            print(
                "heartbeat: "
                f"feature={snapshot['feature']} "
                f"pod={snapshot['pod_id']} "
                f"age={age_text} "
                f"owner_pid={snapshot['owner_pid']} "
                f"stale={'yes' if stale else 'no'} "
                f"path={snapshot['path']}"
            )
    else:
        print("heartbeat: none")

    print(f"log: {LOG_PATH}")
    return 0


def reap_now() -> int:
    snapshots = heartbeat_snapshots()
    if not snapshots:
        print("No heartbeat file / pod registration present.")
        return 0

    reaped_any = False
    for snapshot in snapshots:
        pod_id = snapshot["pod_id"]
        age = snapshot["age"]
        owner_pid = snapshot["owner_pid"]
        path = snapshot["path"]
        feature = snapshot["feature"]

        if age is None:
            print(f"Heartbeat exists for pod {pod_id} ({feature}), but timestamp is unreadable.")
            continue
        if age <= STALE_SECONDS:
            print(f"Heartbeat for pod {pod_id} ({feature}) is fresh ({int(age)}s old); not reaping.")
            continue
        terminate_pod(pod_id, f"manual reap feature={feature} owner_pid={owner_pid} age={int(age)}s")
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        reaped_any = True

    if not reaped_any:
        print("No stale registered pods found.")
    return 0


def terminate_command(pod_id: str) -> int:
    terminate_pod(pod_id, "manual terminate command")
    return 0


def usage() -> int:
    print(
        "Usage: runpod_pod_monitor.py "
        "[ensure-monitor|run|status|reap-now|terminate <pod_id>]"
    )
    return 1


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return usage()

    command = argv[1]
    if command == "ensure-monitor":
        return ensure_monitor()
    if command == "run":
        return monitor_loop()
    if command == "status":
        return status()
    if command == "reap-now":
        return reap_now()
    if command == "terminate" and len(argv) == 3:
        return terminate_command(argv[2])
    return usage()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
