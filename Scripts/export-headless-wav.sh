#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$REPO_ROOT/Packages/NovotroScore"
COOLDOWN_SECONDS="${NOVOTRO_HEADLESS_EXPORT_COOLDOWN_SECONDS:-5}"
COOLDOWN_STAMP="${TMPDIR:-/tmp}/novotro-headless-export.last-exit"
ALLOW_BLUETOOTH_OUTPUT="${NOVOTRO_ALLOW_BLUETOOTH_OUTPUT:-0}"
SCORE_BIN_OVERRIDE="${NOVOTRO_SCORE_BIN:-}"
OUTPUT_PATH=""

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
  - It does NOT require opening Amira Writer.app.
  - Override the executable with NOVOTRO_SCORE_BIN if you want to use a prebuilt binary.
EOF
  exit 2
fi

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output" ]] && (( i + 1 < ${#args[@]} )); then
    OUTPUT_PATH="${args[$((i + 1))]}"
    break
  fi
done

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

"${RUNNER[@]}" --headless-export-wav "$@" &
runner_pid=$!

verify_waveform() {
  local wav_path="$1"
  if [[ ! -f "$wav_path" ]]; then
    echo "ERROR: Output WAV file not found: $wav_path" >&2
    return 1
  fi

  local file_size
  file_size="$(stat -f%z "$wav_path" 2>/dev/null || echo 0)"
  if (( file_size < 100000 )); then
    echo "ERROR: Output WAV file too small (${file_size} bytes): $wav_path" >&2
    return 1
  fi

  # Use afinfo to check for non-silence. afinfo reports "estimated duration"
  # and "audio bytes". We also use sox (if available) or afinfo peak level.
  local peak_db
  if command -v sox &>/dev/null; then
    # sox stat gives us Maximum amplitude directly
    peak_db="$(sox "$wav_path" -n stat 2>&1 | awk '/Maximum amplitude/ { print $3 }')"
    if [[ -n "$peak_db" ]] && (( $(echo "$peak_db < 0.001" | bc -l 2>/dev/null || echo 0) )); then
      echo "WARNING: WAV appears silent (peak amplitude: $peak_db)" >&2
      return 2
    fi
  else
    # Fallback: use afclip or just check audio bytes > threshold
    local audio_bytes
    audio_bytes="$(afinfo "$wav_path" 2>/dev/null | awk '/audio bytes:/ { print $3; exit }')"
    if [[ "$audio_bytes" =~ ^[0-9]+$ ]] && (( audio_bytes < 1000 )); then
      echo "WARNING: WAV has very few audio bytes ($audio_bytes) — likely silent" >&2
      return 2
    fi
  fi

  echo "Waveform verified: ${file_size} bytes, non-silent" >&2
  return 0
}

finalize_and_exit() {
  local status="$1"
  date +%s > "$COOLDOWN_STAMP"

  # Verify waveform on successful export
  if [[ "$status" -eq 0 ]] && [[ -n "$OUTPUT_PATH" ]]; then
    verify_waveform "$OUTPUT_PATH"
    local verify_status=$?
    if [[ "$verify_status" -eq 2 ]]; then
      echo "WARNING: Export completed but WAV may be silent. Check the file." >&2
      # Exit with special code so callers can detect silent exports
      exit 10
    elif [[ "$verify_status" -ne 0 ]]; then
      exit 11
    fi
  fi

  exit "$status"
}

last_size=-1
stable_polls=0

while kill -0 "$runner_pid" 2>/dev/null; do
  if [[ -n "$OUTPUT_PATH" ]] && [[ -f "$OUTPUT_PATH" ]]; then
    current_size="$(stat -f%z "$OUTPUT_PATH" 2>/dev/null || echo 0)"
    audio_bytes="$(
      afinfo "$OUTPUT_PATH" 2>/dev/null | awk '
        /audio bytes:/ {
          print $3
          exit
        }
      '
    )"

    if [[ "$current_size" =~ ^[0-9]+$ ]] && [[ "$audio_bytes" =~ ^[0-9]+$ ]] \
      && (( current_size > 100000 )) && (( audio_bytes > 100000 )); then
      if [[ "$current_size" == "$last_size" ]]; then
        stable_polls=$(( stable_polls + 1 ))
      else
        stable_polls=0
      fi

      if (( stable_polls >= 2 )); then
        kill -TERM "$runner_pid" 2>/dev/null || true
        for _ in {1..10}; do
          if ! kill -0 "$runner_pid" 2>/dev/null; then
            finalize_and_exit 0
          fi
          sleep 1
        done
        kill -KILL "$runner_pid" 2>/dev/null || true
        finalize_and_exit 0
      fi
    else
      stable_polls=0
    fi

    last_size="$current_size"
  fi

  sleep 5
done

wait "$runner_pid"
status=$?
finalize_and_exit "$status"
