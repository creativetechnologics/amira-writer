#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$REPO_ROOT/Packages/NovotroScore"
COOLDOWN_SECONDS="${NOVOTRO_HEADLESS_EXPORT_COOLDOWN_SECONDS:-5}"
COOLDOWN_STAMP="${TMPDIR:-/tmp}/novotro-headless-export.last-exit"
ALLOW_BLUETOOTH_OUTPUT="${NOVOTRO_ALLOW_BLUETOOTH_OUTPUT:-0}"
SCORE_BIN_OVERRIDE="${NOVOTRO_SCORE_BIN:-}"

if [[ ! -f "$PACKAGE_ROOT/Package.swift" ]]; then
  echo "NovotroScore package not found at: $PACKAGE_ROOT" >&2
  exit 1
fi

if [[ $# -lt 4 ]]; then
  cat >&2 <<'EOF'
Usage:
  Scripts/export-headless-wav.sh \
    --project /path/to/project.owp \
    --output /path/to/out.wav \
    [--song-path 'Songs/1.01.0 - OVERTURE.ows' | --song-index 0] \
    [--start-tick 0] \
    [--end-tick 48000] \
    [--override-sf2 /path/to/file.sf2]

Notes:
  - This script runs the repo-local NovotroScore package executable in headless mode.
  - It does NOT require opening Novotro Opera.app.
  - Override the executable with NOVOTRO_SCORE_BIN if you want to use a prebuilt binary.
EOF
  exit 2
fi

if [[ "$ALLOW_BLUETOOTH_OUTPUT" != "1" ]]; then
  default_output_device="$(
    system_profiler SPAudioDataType 2>/dev/null | awk '
      /^[[:space:]]{8}[^:]+:$/ {
        device = $0
        gsub(/^[[:space:]]+/, "", device)
        sub(/:$/, "", device)
      }
      /Default Output Device: Yes/ {
        print device
        exit
      }
    '
  )"

  if echo "$default_output_device" | grep -qi 'AirPods'; then
    echo "Refusing headless export while AirPods are the default output device: $default_output_device" >&2
    echo "Switch output to built-in speakers first, then retry." >&2
    echo "Override guard with NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1 if needed." >&2
    exit 3
  fi

  connected_airpods="$(
    system_profiler SPBluetoothDataType 2>/dev/null | awk '
      /Connected:/ { in_connected = 1; next }
      /Not Connected:/ { in_connected = 0; next }
      in_connected && /^[[:space:]]+[[:graph:]].*:$/ {
        item = $0
        gsub(/^[[:space:]]+/, "", item)
        sub(/:$/, "", item)
        if (item ~ /AirPods/) {
          print item
          exit
        }
      }
    '
  )"

  if [[ -n "$connected_airpods" ]]; then
    echo "Refusing headless export while AirPods are connected: $connected_airpods" >&2
    echo "Disconnect AirPods (or disable Bluetooth) first, then retry." >&2
    echo "Override guard with NOVOTRO_ALLOW_BLUETOOTH_OUTPUT=1 if needed." >&2
    exit 4
  fi
fi

if [[ -f "$COOLDOWN_STAMP" ]]; then
  last_exit_epoch="$(<"$COOLDOWN_STAMP")"
  now_epoch="$(date +%s)"
  if [[ "$last_exit_epoch" =~ ^[0-9]+$ ]] && [[ "$COOLDOWN_SECONDS" =~ ^[0-9]+$ ]]; then
    elapsed="$(( now_epoch - last_exit_epoch ))"
    if (( elapsed < COOLDOWN_SECONDS )); then
      sleep "$(( COOLDOWN_SECONDS - elapsed ))"
    fi
  fi
fi

if [[ -n "$SCORE_BIN_OVERRIDE" ]]; then
  if [[ ! -x "$SCORE_BIN_OVERRIDE" ]]; then
    echo "NOVOTRO_SCORE_BIN is not executable: $SCORE_BIN_OVERRIDE" >&2
    exit 5
  fi
  RUNNER=("$SCORE_BIN_OVERRIDE")
else
  RUNNER=(swift run --package-path "$PACKAGE_ROOT" -c release NovotroScore)
fi

"${RUNNER[@]}" --headless-export-wav "$@"
status=$?
date +%s > "$COOLDOWN_STAMP"
exit "$status"
