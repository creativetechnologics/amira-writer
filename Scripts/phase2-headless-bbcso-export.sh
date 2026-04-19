#!/usr/bin/env bash
# phase2-headless-bbcso-export.sh
# Phase 2b validation: headless BBC SO offline export, faster-than-realtime.
#
# What this does:
#   1. Clears the v14 qualification cache so no stale rejection blocks the run
#   2. Launches Amira Writer.app with AMIRA_HEADLESS_FORCE_OFFLINE=1 (skips
#      qualification entirely, routes straight to offline AVAudioEngine render)
#   3. Times wall-clock launch→WAV-written duration
#   4. Validates WAV with afinfo (duration, audio bytes)
#   5. Spectral sanity check via Python: energy in 500 Hz–8 kHz band must be
#      non-trivial relative to the 200–500 Hz band (> -40 dB relative)
#   6. Prints PASS / FAIL with diagnostics
#
# Usage:
#   Scripts/phase2-headless-bbcso-export.sh
#
# Env overrides:
#   PHASE2_SONG_HINT    — song name hint (default: "Overture")
#   PHASE2_OUTPUT_WAV   — override output WAV path
#   PHASE2_TIMEOUT_SECS — wall-clock timeout before FAIL (default: 300)
set -euo pipefail

APP_BUNDLE="/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
CACHE_FILE="$HOME/Library/Application Support/Opera/HostedAudioUnitQualificationCache.json"

TMP_DIR="/private/tmp/amira-phase2-bbcso"
OUTPUT_WAV="${PHASE2_OUTPUT_WAV:-$TMP_DIR/overture.wav}"
LOG_FILE="$TMP_DIR/overture.headless-log.txt"
SONG_HINT="${PHASE2_SONG_HINT:-Overture}"
TIMEOUT_SECS="${PHASE2_TIMEOUT_SECS:-300}"

# --- Validate prerequisites ---------------------------------------------------
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

if ! python3 -c "import soundfile, numpy" 2>/dev/null; then
  echo "Installing required Python packages..."
  pip3 install soundfile numpy --quiet
fi

mkdir -p "$TMP_DIR"
rm -f "$OUTPUT_WAV" "$LOG_FILE"

echo "=== Phase 2b: Headless BBC SO offline export ==="
echo "  App     : $APP_BUNDLE"
echo "  Output  : $OUTPUT_WAV"
echo "  Song    : $SONG_HINT"
echo "  Log     : $LOG_FILE"
echo "  Timeout : ${TIMEOUT_SECS}s"
echo ""

# --- Clear v14 qualification cache --------------------------------------------
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_BACKUP="$TMP_DIR/QualificationCache.backup.json"
  cp "$CACHE_FILE" "$CACHE_BACKUP"
  rm -f "$CACHE_FILE"
  echo "Cleared qualification cache (backup: $CACHE_BACKUP)"
else
  echo "Qualification cache not present — nothing to clear."
fi

# --- Kill any stale Opera processes -------------------------------------------
pkill -x "Amira Writer" 2>/dev/null || true
sleep 1

# --- Launch app and time it ---------------------------------------------------
echo ""
echo "Launching app with AMIRA_HEADLESS_FORCE_OFFLINE=1 ..."
WALL_START=$(date +%s)

open -W -n \
  --env AMIRA_HEADLESS_FULLMIX_EXPORT="$OUTPUT_WAV" \
  --env AMIRA_HEADLESS_FULLMIX_SONG="$SONG_HINT" \
  --env AMIRA_HEADLESS_FORCE_OFFLINE=1 \
  --env AMIRA_HEADLESS_LOG_FILE="$LOG_FILE" \
  "$APP_BUNDLE" &
APP_PID=$!

# Poll for the "done" line in the app log — wait for full completion, not just file creation.
# The app writes [HeadlessFullMix] done status=... when the WAV is fully flushed.
WAIT=0
DONE=0
while [[ $WAIT -lt $TIMEOUT_SECS ]]; do
  if [[ -f "$LOG_FILE" ]] && grep -q "\[HeadlessFullMix\] done status=success" "$LOG_FILE" 2>/dev/null; then
    DONE=1
    break
  fi
  # Also check for error termination
  if [[ -f "$LOG_FILE" ]] && grep -q "\[HeadlessFullMix\] done status=error" "$LOG_FILE" 2>/dev/null; then
    echo "Export reported error status."
    break
  fi
  # Check if app process died unexpectedly
  if ! kill -0 $APP_PID 2>/dev/null; then
    # App exited — check if WAV was written
    if [[ -f "$OUTPUT_WAV" ]] && [[ $(stat -f%z "$OUTPUT_WAV" 2>/dev/null || echo 0) -gt 4096 ]]; then
      DONE=1
    fi
    break
  fi
  sleep 2
  WAIT=$((WAIT + 2))
done

if [[ $DONE -eq 0 && $WAIT -ge $TIMEOUT_SECS ]]; then
  echo "TIMEOUT after ${TIMEOUT_SECS}s — export did not complete."
  kill $APP_PID 2>/dev/null || true
  echo "FAIL: export timed out"
  exit 1
fi

# Give app a moment to fully terminate
sleep 2
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true

WALL_END=$(date +%s)
WALL_ELAPSED=$((WALL_END - WALL_START))

echo ""
echo "=== Wall-clock: ${WALL_ELAPSED}s ==="

# --- WAV inspection -----------------------------------------------------------
echo ""
echo "--- WAV inspection ---"
WAV_BYTES=$(stat -f%z "$OUTPUT_WAV" 2>/dev/null || echo 0)
echo "WAV file size: ${WAV_BYTES} bytes"

# Use afinfo for header info (may report duration=0 for non-interleaved float WAVs — that's OK)
afinfo "$OUTPUT_WAV" 2>/dev/null || true

# Use soundfile (Python) for reliable duration — afinfo misreads non-interleaved Float32 headers
WAV_DURATION=$(python3 -c "
import soundfile as sf, sys
try:
    info = sf.info(sys.argv[1])
    print(f'{info.frames / info.samplerate:.2f}')
except Exception as e:
    print('0')
" "$OUTPUT_WAV" 2>/dev/null || echo "0")

echo ""
echo "WAV duration (soundfile): ${WAV_DURATION}s"

# --- Speedup ratio from in-app log -------------------------------------------
SPEEDUP_LINE=""
if [[ -f "$LOG_FILE" ]]; then
  SPEEDUP_LINE=$(grep "wall-clock time=" "$LOG_FILE" | tail -1 || true)
  if [[ -n "$SPEEDUP_LINE" ]]; then
    echo ""
    echo "In-app timing: $SPEEDUP_LINE"
  fi
fi

# --- Spectral sanity check ---------------------------------------------------
echo ""
echo "--- Spectral sanity (Python) ---"
python3 - "$OUTPUT_WAV" <<'PYEOF'
import sys, math
try:
    import soundfile as sf
    import numpy as np
except ImportError:
    print("SPECTRAL_SKIP: soundfile/numpy not available")
    sys.exit(0)

wav_path = sys.argv[1]
try:
    data, sr = sf.read(wav_path, always_2d=True)
except Exception as e:
    print(f"SPECTRAL_ERROR: could not read WAV: {e}")
    sys.exit(1)

total_frames = data.shape[0]
if total_frames < sr * 5:
    print(f"SPECTRAL_WARN: file too short ({total_frames/sr:.1f}s) for spectral check")
    sys.exit(0)

# Take middle 10 seconds
mid = total_frames // 2
half = int(sr * 5)
segment = data[mid - half : mid + half, 0]  # mono, left channel

# FFT
N = len(segment)
fft_mag = np.abs(np.fft.rfft(segment))
freqs = np.fft.rfftfreq(N, d=1.0/sr)

def band_rms(lo, hi):
    mask = (freqs >= lo) & (freqs < hi)
    vals = fft_mag[mask]
    if len(vals) == 0:
        return 0.0
    return float(np.sqrt(np.mean(vals**2)))

b_low   = band_rms(20,   200)   # sub-bass / bass
b_mid_l = band_rms(200,  500)   # low-mid (reference)
b_mid_h = band_rms(500,  8000)  # mid/presence (the key test)
b_hi    = band_rms(8000, 16000) # air

def db_rel(a, ref):
    if ref <= 0 or a <= 0:
        return -999.0
    return 20 * math.log10(a / ref)

rel_midh = db_rel(b_mid_h, b_mid_l)
rel_hi   = db_rel(b_hi,    b_mid_l)

print(f"  20-200 Hz  band RMS : {b_low:.4f}")
print(f"  200-500 Hz band RMS : {b_mid_l:.4f}  (reference)")
print(f"  500-8kHz   band RMS : {b_mid_h:.4f}  ({rel_midh:+.1f} dB vs reference)")
print(f"  8k-16kHz   band RMS : {b_hi:.4f}  ({rel_hi:+.1f} dB vs reference)")

# Threshold: 500-8kHz must be within -40 dB of 200-500 Hz reference
THRESHOLD_DB = -40.0
if b_mid_l <= 0:
    print("SPECTRAL_FAIL: reference band (200-500 Hz) is silent — no audio content")
    sys.exit(2)
elif rel_midh < THRESHOLD_DB:
    print(f"SPECTRAL_FAIL: 500-8kHz band is {rel_midh:.1f} dB below reference (threshold {THRESHOLD_DB:.0f} dB) — samples not loaded")
    sys.exit(2)
else:
    print(f"SPECTRAL_PASS: 500-8kHz band is {rel_midh:.1f} dB vs reference (threshold {THRESHOLD_DB:.0f} dB)")
    sys.exit(0)
PYEOF
SPECTRAL_EXIT=$?

# --- Final verdict ------------------------------------------------------------
echo ""
echo "========================================"

FAIL_REASONS=()

# Check WAV size (must be > 4 KB)
if [[ "${WAV_BYTES:-0}" -le 4096 ]]; then
  FAIL_REASONS+=("WAV file is too small (${WAV_BYTES} bytes) — likely incomplete")
fi

# Check WAV audio duration (must be > 10s — indicates real content was rendered)
WAV_DUR_INT=$(python3 -c "print(int(float('${WAV_DURATION:-0}')))" 2>/dev/null || echo 0)
if [[ $WAV_DUR_INT -lt 10 ]]; then
  FAIL_REASONS+=("WAV audio duration is ${WAV_DURATION:-0}s (< 10s) — export appears incomplete")
fi

# Check wall-clock < 180s (Overture is ~180s audio)
if [[ $WALL_ELAPSED -ge 180 ]]; then
  FAIL_REASONS+=("Wall-clock ${WALL_ELAPSED}s >= 180s — not faster than realtime")
fi

# Check spectral
if [[ $SPECTRAL_EXIT -eq 2 ]]; then
  FAIL_REASONS+=("Spectral check failed — BBC SO samples not loaded (silent above 500 Hz)")
fi

if [[ ${#FAIL_REASONS[@]} -eq 0 ]]; then
  echo "PASS"
  echo "  Wall-clock export time : ${WALL_ELAPSED}s"
  echo "  Audio duration         : ${WAV_DURATION:-?}s"
  if [[ $WALL_ELAPSED -gt 0 && -n "${WAV_DURATION:-}" ]]; then
    SPEEDUP_RATIO=$(python3 -c "print(f'{float(\"$WAV_DURATION\") / $WALL_ELAPSED:.2f}x')" 2>/dev/null || echo "?")
    echo "  Speedup ratio          : $SPEEDUP_RATIO"
  fi
  [[ -n "$SPEEDUP_LINE" ]] && echo "  In-app log             : $SPEEDUP_LINE"
else
  echo "FAIL"
  for reason in "${FAIL_REASONS[@]}"; do
    echo "  - $reason"
  done
  echo ""
  echo "Diagnostic data:"
  echo "  Wall-clock: ${WALL_ELAPSED}s"
  echo "  WAV size  : ${WAV_BYTES} bytes"
  echo "  WAV dur   : ${WAV_DURATION:-unknown}s"
  if [[ -f "$LOG_FILE" ]]; then
    echo ""
    echo "--- Last 40 lines of app log ---"
    tail -40 "$LOG_FILE"
  fi
fi
echo "========================================"
