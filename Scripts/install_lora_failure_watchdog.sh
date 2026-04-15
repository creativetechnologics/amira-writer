#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/Scripts/lora_failure_watchdog.py"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_ID="com.amira.writer.lora-failure-watchdog"
LAUNCH_AGENT_PATH="$LAUNCH_AGENTS_DIR/${LAUNCH_AGENT_ID}.plist"
LOG_DIR="$HOME/Library/Logs/Amira"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "$PYTHON_BIN" ]]; then
  echo "error: python3 not found" >&2
  exit 1
fi

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

cat > "$LAUNCH_AGENT_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_BIN}</string>
        <string>${SCRIPT_PATH}</string>
        <string>watch</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/lora_failure_watchdog.launchd.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/lora_failure_watchdog.launchd.stderr.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_ID}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_ID}"

printf 'Installed %s\n' "$LAUNCH_AGENT_ID"
printf 'Launch agent: %s\n' "$LAUNCH_AGENT_PATH"
"$PYTHON_BIN" "$SCRIPT_PATH" status
