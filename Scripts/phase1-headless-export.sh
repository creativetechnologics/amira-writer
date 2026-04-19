#!/usr/bin/env bash
# phase1-headless-export.sh
# Phase 1d driver: launch Amira Writer.app via `open --env` so env vars
# are reliably inherited by the app process (launchctl setenv is NOT inherited
# by apps launched via open/LaunchServices — use open --env instead).
#
# What's new in 1d:
#   - Qualification cache is CLEARED before the run (backed up first) so the
#     scanner fix is exercised against a fresh BBC Symphony Orchestra AU render.
#   - AMIRA_HEADLESS_LOG_FILE is passed so the in-process dup2 redirect writes
#     ALL NSLog / stderr output to a capturable file (no log stream needed).
#   - Harvest section greps the app-side log file, not log stream.
#
# Usage:
#   Scripts/phase1-headless-export.sh
#
# Output WAV: /private/tmp/amira-phase1d/overture.wav
# Log file  : /private/tmp/amira-phase1d/overture.headless-log.txt
#
# Env overrides:
#   PHASE1_SONG_HINT   — song name hint (default: "Overture")
#   PHASE1_OUTPUT_WAV  — override output WAV path
set -euo pipefail

APP_BUNDLE="/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
ARTIFACTS_DIR="$HOME/Library/Application Support/Opera/HostedAudioUnitQualificationArtifacts"
CACHE_FILE="$HOME/Library/Application Support/Opera/HostedAudioUnitQualificationCache.json"

TMP_DIR="/private/tmp/amira-phase1d"
OUTPUT_WAV="${PHASE1_OUTPUT_WAV:-$TMP_DIR/overture.wav}"
# The app derives the log path as <output stem>.headless-log.txt when
# AMIRA_HEADLESS_LOG_FILE is not set.  Set it explicitly so we know exactly
# where to find it.
LOG_FILE="$TMP_DIR/overture.headless-log.txt"
SONG_HINT="${PHASE1_SONG_HINT:-Overture}"

# --- Validate app bundle -------------------------------------------------------
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found at: $APP_BUNDLE" >&2
  exit 1
fi

# --- Create temp dir -----------------------------------------------------------
mkdir -p "$TMP_DIR"

echo "=== Phase 1d headless export via open --env ==="
echo "  App    : $APP_BUNDLE"
echo "  Output : $OUTPUT_WAV"
echo "  Song   : $SONG_HINT"
echo "  Log    : $LOG_FILE"
echo ""

# --- Clear qualification cache (back up first, then delete) -------------------
# This forces a fresh qualification run so the Phase 1d scanner fix is actually
# exercised; prior phases may have left a v13-rejected entry in the cache.
CACHE_BACKUP=""
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_BACKUP="$TMP_DIR/HostedAudioUnitQualificationCache.backup.json"
  cp "$CACHE_FILE" "$CACHE_BACKUP"
  rm -f "$CACHE_FILE"
  echo "Qualification cache cleared (backup: $CACHE_BACKUP)"
else
  echo "No qualification cache file found — fresh run."
fi

# --- Launch app with env vars injected via open --env -------------------------
# IMPORTANT: launchctl setenv writes to the launchd bootstrap context but is NOT
# inherited by apps launched via open/LaunchServices. The `open --env` flag
# passes the variable directly into the launched process environment.
echo "Launching app (open -W -n --env)..."
LAUNCH_START="$(date +%s)"

# 10-minute wall-clock cap (600 s). Qualification adds ~30-60s on top of 3 min realtime.
TIMEOUT_SECS=600

# open -W blocks until the app quits; -n forces a fresh instance
# --env injects vars directly into the child process (reliable; no launchctl needed)
open -W -n \
  --env "AMIRA_HEADLESS_FULLMIX_EXPORT=$OUTPUT_WAV" \
  --env "AMIRA_HEADLESS_FULLMIX_SONG=$SONG_HINT" \
  --env "AMIRA_HEADLESS_LOG_FILE=$LOG_FILE" \
  "$APP_BUNDLE" &
OPEN_PID=$!

# Wait up to TIMEOUT_SECS, then kill if still running
(
  sleep "$TIMEOUT_SECS"
  if kill -0 "$OPEN_PID" 2>/dev/null; then
    echo "TIMEOUT: app still running after ${TIMEOUT_SECS}s — killing PID $OPEN_PID" >&2
    # Kill the app process (find by bundle ID)
    APP_PID=$(pgrep -f "Amira Writer.app/Contents/MacOS" 2>/dev/null | head -1 || true)
    if [[ -n "$APP_PID" ]]; then
      kill -TERM "$APP_PID" 2>/dev/null || true
      sleep 3
      kill -9  "$APP_PID" 2>/dev/null || true
    fi
    kill -TERM "$OPEN_PID" 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

wait "$OPEN_PID" 2>/dev/null || true
LAUNCH_STATUS=$?

# Cancel watchdog if app exited normally
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

LAUNCH_END="$(date +%s)"
ELAPSED=$(( LAUNCH_END - LAUNCH_START ))

echo ""
echo "=== App ran for ${ELAPSED}s, exit status: $LAUNCH_STATUS ==="
echo ""

# --- Restore qualification cache ----------------------------------------------
if [[ -n "$CACHE_BACKUP" && -f "$CACHE_BACKUP" ]]; then
  cp "$CACHE_BACKUP" "$CACHE_FILE"
  echo "Qualification cache restored from backup."
fi

# --- Harvest relevant log lines from the app-side log file --------------------
if [[ ! -f "$LOG_FILE" ]]; then
  echo "WARNING: Log file not found: $LOG_FILE" >&2
  echo "  (dup2 redirect may not have fired — check if app launched correctly)"
  LOG_FILE=""
fi

if [[ -n "$LOG_FILE" ]]; then
  LOG_SIZE="$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
  echo "Log file size: ${LOG_SIZE} bytes"
  echo ""

  echo "--- [Phase1cHook] entries ---"
  grep '\[Phase1cHook\]' "$LOG_FILE" || echo "(none)"

  echo ""
  echo "--- [HeadlessFullMix] entries ---"
  grep '\[HeadlessFullMix\]' "$LOG_FILE" || echo "(none)"

  echo ""
  echo "--- [Phase0Bounds] entries ---"
  grep '\[Phase0Bounds\]' "$LOG_FILE" || echo "(none)"

  echo ""
  echo "--- [Phase0Tap] entries (first 20) ---"
  grep '\[Phase0Tap\]' "$LOG_FILE" | head -20 || echo "(none)"

  echo ""
  echo "--- [Phase1Bounds] entries ---"
  grep '\[Phase1Bounds\]' "$LOG_FILE" || echo "(none)"

  echo ""
  echo "--- [OfflineExport] Qualification entries ---"
  grep '\[OfflineExport\] Qualification' "$LOG_FILE" || echo "(none)"

  echo ""
  echo "--- AU instantiation / OSStatus errors ---"
  grep -i 'OSStatus\|audioUnit.*error\|-3000\|Component.*fail\|instantiat.*fail\|\[OfflineExport\].*fail' "$LOG_FILE" | head -30 || echo "(none)"

  echo ""
  echo "--- Full log (last 80 lines) ---"
  tail -80 "$LOG_FILE"
fi

# --- Check output WAV ---------------------------------------------------------
echo ""
echo "=== WAV verification ==="
if [[ -f "$OUTPUT_WAV" ]]; then
  FILE_SIZE="$(stat -f%z "$OUTPUT_WAV" 2>/dev/null || echo 0)"
  echo "File size  : ${FILE_SIZE} bytes"

  # afinfo for duration + audio bytes
  AFINFO_OUT="$(afinfo "$OUTPUT_WAV" 2>&1 || true)"
  echo "afinfo output:"
  echo "$AFINFO_OUT"

  # Extended afinfo
  echo ""
  echo "afinfo -x output (first 40 lines):"
  afinfo -x "$OUTPUT_WAV" 2>&1 | head -40 || true

  # Sample middle of file to check for non-zero content
  echo ""
  echo "Non-zero sample check (middle 4096 bytes of audio data):"
  HEADER_OFFSET=44  # standard PCM WAV header
  MID_OFFSET=$(( FILE_SIZE / 2 ))
  if (( MID_OFFSET > HEADER_OFFSET )); then
    # Read 4096 bytes from the middle, check if any non-zero
    NON_ZERO="$(dd if="$OUTPUT_WAV" bs=1 skip="$MID_OFFSET" count=4096 2>/dev/null | xxd | grep -v ' 0000 0000 0000 0000 0000 0000 0000 0000' | wc -l | tr -d ' ')"
    echo "Non-zero rows at mid-file: $NON_ZERO  (0 = silent)"
  else
    echo "(file too small to sample middle)"
  fi
else
  echo "ERROR: Output WAV not found: $OUTPUT_WAV" >&2
fi

echo ""

# --- Inspect newest qualification artifact ------------------------------------
echo "=== Newest qualification artifact ==="
if [[ -d "$ARTIFACTS_DIR" ]]; then
  NEWEST_DIR="$(ls -td "$ARTIFACTS_DIR"/*/ 2>/dev/null | head -1)"
  if [[ -n "$NEWEST_DIR" ]]; then
    echo "Dir: $NEWEST_DIR"
    METADATA_FILE="$NEWEST_DIR/metadata.json"
    if [[ -f "$METADATA_FILE" ]]; then
      echo "metadata.json:"
      python3 -c "
import json, sys
with open('$METADATA_FILE') as f:
    d = json.load(f)
print('  verdict     :', d.get('verdict','?'))
print('  detail      :', d.get('detail','?'))
# Parse onsetDelta and tailDelta from detail string
detail = d.get('detail','')
import re
for field in ['onsetDelta', 'tailDelta', 'similarity', 'envelope', 'activeDelta', 'fileDelta']:
    m = re.search(field + r'=([^\s]+)', detail)
    print(f'  {field:15s}:', m.group(1) if m else '(not found)')
"
    else
      echo "(no metadata.json)"
    fi
  else
    echo "(no artifact dirs found)"
  fi
else
  echo "(artifacts dir not found)"
fi

echo ""
echo "=== Phase 1d run complete ==="
echo "Full log: ${LOG_FILE:-N/A}"
