#!/usr/bin/env python3
"""Background watchdog for Amira RunPod LoRA failures.

This monitor watches ~/Library/Application Support/Amira/active-runpod-lora-job.json.
When a new failed training job appears, it classifies the failure, attempts safe
automatic remediation for known cases (currently: syncing the latest server app
bundle to the laptop when a newer fix exists), writes a report, and sends a macOS
notification so Gary can retry from the repaired build.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

SUPPORT_DIR = Path.home() / 'Library/Application Support/Amira'
JOB_PATH = SUPPORT_DIR / 'active-runpod-lora-job.json'
STATE_PATH = SUPPORT_DIR / 'lora_failure_watchdog_state.json'
REPORT_DIR = SUPPORT_DIR / 'FailureReports'
LOG_DIR = Path.home() / 'Library/Logs/Amira'
LOG_PATH = LOG_DIR / 'lora_failure_watchdog.log'
PID_PATH = SUPPORT_DIR / 'lora_failure_watchdog.pid'

LOCAL_APP = Path.home() / 'Programming/!Applications/Amira Writer.app'
SERVER_HOST = 'gary@Garys-Server.local'
SERVER_APP = '/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app'
POLL_SECONDS = 20
LABEL = 'com.amira.writer.lora-failure-watchdog'


def now_local() -> dt.datetime:
    return dt.datetime.now().astimezone()


def log(message: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"[{now_local().strftime('%Y-%m-%d %H:%M:%S %Z')}] {message}\n"
    with LOG_PATH.open('a', encoding='utf-8') as handle:
        handle.write(line)
    print(message)


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        log(f'Invalid JSON at {path}: {exc}')
        return None
    return data if isinstance(data, dict) else None


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding='utf-8')


def load_state() -> dict[str, Any]:
    return read_json(STATE_PATH) or {'handled_failures': {}}


def save_state(state: dict[str, Any]) -> None:
    write_json(STATE_PATH, state)


def parse_completed_at(job: dict[str, Any]) -> str:
    value = job.get('completedAt')
    if value is None:
        return 'unknown'
    return str(value)


def failure_fingerprint(job: dict[str, Any]) -> str:
    return f"{job.get('id','unknown')}::{parse_completed_at(job)}::{job.get('status','unknown')}"


def classify_failure(error_text: str) -> str:
    text = error_text.lower()
    if 'huggingface access missing' in text or '403 client error: forbidden' in text:
        return 'huggingface_access'
    if 'flux_2_cache_latents.py' in text and 'sigsegv' in text:
        return 'latent_cache_sigsegv'
    if 'caching_text_encoder' in text and ('fp8' in text or 'calledprocesserror' in text):
        return 'text_encoder_cache'
    if 'broken pipe' in text or 'operation timed out' in text:
        return 'ssh_transport_drop'
    return 'unknown'


def ssh_capture(command: str) -> str:
    result = subprocess.run(
        ['ssh', SERVER_HOST, f'/bin/zsh -lc {json.dumps(command)}'],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f'ssh failed ({result.returncode})')
    return result.stdout.strip()


def remote_mtime_epoch() -> int | None:
    try:
        output = ssh_capture(f"stat -f '%m' {json.dumps(SERVER_APP)}")
        return int(output.strip())
    except Exception as exc:
        log(f'Could not read server app mtime: {exc}')
        return None


def local_mtime_epoch() -> int | None:
    try:
        return int(LOCAL_APP.stat().st_mtime)
    except FileNotFoundError:
        return None


def sync_latest_server_app_if_newer() -> tuple[bool, str]:
    remote_mtime = remote_mtime_epoch()
    if remote_mtime is None:
        return False, 'Could not read server app timestamp.'
    local_mtime = local_mtime_epoch() or 0
    if remote_mtime <= local_mtime:
        return False, 'Local app is already current.'

    LOCAL_APP.parent.mkdir(parents=True, exist_ok=True)
    temp_tar = Path(tempfile.gettempdir()) / 'amira-writer-watchdog-update.tar'
    if temp_tar.exists():
        temp_tar.unlink()

    remote_cmd = f"tar -C {json.dumps(str(Path(SERVER_APP).parent))} -cf - {json.dumps(Path(SERVER_APP).name)}"
    with temp_tar.open('wb') as handle:
        proc = subprocess.run(['ssh', SERVER_HOST, f'/bin/zsh -lc {json.dumps(remote_cmd)}'], stdout=handle, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        stderr = proc.stderr.decode('utf-8', errors='replace').strip()
        return False, f'Failed copying server app: {stderr or proc.returncode}'

    temp_root = Path(tempfile.mkdtemp(prefix='amira-watchdog-app-'))
    subprocess.run(['tar', '-C', str(temp_root), '-xf', str(temp_tar)], check=True)
    temp_app = temp_root / 'Amira Writer.app'
    if not temp_app.exists():
        return False, 'Copied server app archive but could not unpack Amira Writer.app.'

    if LOCAL_APP.exists():
        try:
            shutil.rmtree(LOCAL_APP)
        except Exception as exc:
            return False, f'Copied updated app but could not replace local app: {exc}'
    temp_app.rename(LOCAL_APP)
    shutil.rmtree(temp_root, ignore_errors=True)
    return True, 'Copied latest repaired app bundle from Garys-Server.local.'


def write_failure_report(job: dict[str, Any], classification: str, fix_message: str) -> Path:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = now_local().strftime('%Y%m%d-%H%M%S')
    path = REPORT_DIR / f'lora-failure-{stamp}.md'
    body = [
        f'# Amira LoRA Failure Watchdog Report',
        '',
        f'- Time: {now_local().isoformat()}',
        f'- Job ID: {job.get("id", "unknown")}',
        f'- Character: {job.get("characterName", "unknown")}',
        f'- Trigger: {job.get("triggerWord", "unknown")}',
        f'- Base Model: {job.get("config", {}).get("baseModel", "unknown")}',
        f'- Classification: {classification}',
        f'- Auto-fix result: {fix_message}',
        '',
        '## Error',
        '',
        '```',
        (job.get('errorMessage') or '').strip(),
        '```',
    ]
    path.write_text('\n'.join(body), encoding='utf-8')
    return path


def notify(title: str, subtitle: str, message: str) -> None:
    script = (
        'on run argv\n'
        'display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv) sound name "Submarine"\n'
        'end run'
    )
    subprocess.run(['osascript', '-e', script, title, subtitle, message], check=False)


def remediation_for(job: dict[str, Any], classification: str) -> str:
    synced, sync_message = sync_latest_server_app_if_newer()
    if classification == 'huggingface_access':
        return f'{sync_message} Manual action still required: grant Hugging Face access for the selected repo.'
    if synced:
        return sync_message
    if classification == 'latent_cache_sigsegv':
        return f'{sync_message} This failure matched the known 9B latent-cache crash signature.'
    if classification == 'text_encoder_cache':
        return f'{sync_message} This failure matched the known text-encoder cache issue.'
    return sync_message


def handle_failure(job: dict[str, Any], state: dict[str, Any]) -> None:
    fingerprint = failure_fingerprint(job)
    if fingerprint in state.get('handled_failures', {}):
        return

    error_text = job.get('errorMessage') or ''
    classification = classify_failure(error_text)
    log(f'New LoRA failure detected: {fingerprint} ({classification})')
    fix_message = remediation_for(job, classification)
    report_path = write_failure_report(job, classification, fix_message)

    state.setdefault('handled_failures', {})[fingerprint] = {
        'handled_at': now_local().isoformat(),
        'classification': classification,
        'fix_message': fix_message,
        'report_path': str(report_path),
    }
    save_state(state)

    title = 'Amira LoRA failure handled'
    subtitle = f"{job.get('characterName', 'LoRA')} • {classification.replace('_', ' ')}"
    message = fix_message if len(fix_message) < 180 else fix_message[:177] + '...'
    notify(title, subtitle, message)
    log(f'Handled LoRA failure {fingerprint}: {classification} — {fix_message}')


def write_pid() -> None:
    PID_PATH.write_text(str(os.getpid()), encoding='utf-8')


def clear_pid() -> None:
    try:
        PID_PATH.unlink()
    except FileNotFoundError:
        pass


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def ensure_singleton() -> bool:
    try:
        existing = int(PID_PATH.read_text(encoding='utf-8').strip())
    except Exception:
        write_pid()
        return True
    if pid_is_alive(existing):
        print(f'{LABEL} already running (pid {existing})')
        return False
    write_pid()
    return True


def monitor_loop() -> int:
    if not ensure_singleton():
        return 0

    def _exit(signum, _frame):
        log(f'Stopping on signal {signum}')
        clear_pid()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _exit)
    signal.signal(signal.SIGINT, _exit)

    log(f'LoRA failure watchdog started (poll={POLL_SECONDS}s)')
    try:
        while True:
            state = load_state()
            job = read_json(JOB_PATH)
            if job and job.get('status') == 'error':
                handle_failure(job, state)
            time.sleep(POLL_SECONDS)
    finally:
        clear_pid()


def status() -> int:
    pid = None
    try:
        pid = int(PID_PATH.read_text(encoding='utf-8').strip())
    except Exception:
        pass
    state = load_state()
    job = read_json(JOB_PATH)
    print(json.dumps({
        'label': LABEL,
        'running': bool(pid and pid_is_alive(pid)),
        'pid': pid,
        'job_path': str(JOB_PATH),
        'active_job_status': job.get('status') if job else None,
        'handled_failures': len(state.get('handled_failures', {})),
        'log_path': str(LOG_PATH),
    }, indent=2))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in {'watch', 'status'}:
        print('usage: lora_failure_watchdog.py [watch|status]')
        return 2
    if argv[1] == 'watch':
        return monitor_loop()
    return status()


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
