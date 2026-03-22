#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="novotro-project-service"
INSTALL_DIR="${NOVOTRO_INSTALL_DIR:-$HOME/Applications}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_ID="com.novotro.project-service"
LAUNCH_AGENT_PATH="$LAUNCH_AGENTS_DIR/${LAUNCH_AGENT_ID}.plist"
LOG_DIR="$HOME/Library/Logs/NovotroProjectService"
PORT="${NOVOTRO_PROJECT_SERVICE_PORT:-19847}"
SUPPORT_DIR="$HOME/Library/Application Support/Novotro"
TOKEN_PATH="${NOVOTRO_PROJECT_SERVICE_TOKEN_FILE:-$SUPPORT_DIR/project-service-token}"

BUILD_CONFIG="release"
for arg in "$@"; do
    case "$arg" in
        --debug) BUILD_CONFIG="debug" ;;
    esac
done

cd "$REPO_DIR"
swift build -c "$BUILD_CONFIG" --product "$SERVICE_NAME"

BINARY_PATH="$REPO_DIR/.build/$BUILD_CONFIG/$SERVICE_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
    echo "error: built service binary not found at $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR" "$(dirname "$TOKEN_PATH")"

if [[ ! -s "$TOKEN_PATH" ]]; then
    python3 - <<'PY' > "$TOKEN_PATH"
import secrets
print(secrets.token_hex(32))
PY
    chmod 600 "$TOKEN_PATH"
fi

install -m 755 "$BINARY_PATH" "$INSTALL_DIR/$SERVICE_NAME"

cat > "$LAUNCH_AGENT_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${SERVICE_NAME}</string>
        <string>serve</string>
        <string>--port</string>
        <string>${PORT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NOVOTRO_PROJECT_SERVICE_TOKEN_FILE</key>
        <string>${TOKEN_PATH}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
PLIST

cleanup_stale_listener() {
    local pid
    pid="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        sleep 1
        pid="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            kill -9 "$pid" >/dev/null 2>&1 || true
            sleep 1
        fi
    fi
}

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/${LAUNCH_AGENT_ID}" >/dev/null 2>&1 || true
cleanup_stale_listener
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH"
launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_ID}"

for _ in {1..20}; do
    if lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "error: ${SERVICE_NAME} failed to start listening on port ${PORT}" >&2
    exit 1
fi

echo "Installed ${SERVICE_NAME} to ${INSTALL_DIR}/${SERVICE_NAME}"
echo "Launch agent: ${LAUNCH_AGENT_PATH}"
echo "Port: ${PORT}"
echo "Token: ${TOKEN_PATH}"
