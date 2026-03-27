#!/usr/bin/env bash
set -euo pipefail

# Fast local build workflow for Amira Writer.
# Use this for day-to-day iteration to avoid full release compile time.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PRODUCT_NAME="NovotroOpera"
CONFIG="debug"
RUN_BINARY=false
SKIP_UPDATE=true

usage() {
    cat <<'USAGE'
Usage:
  build-opera-dev.sh [--run] [--no-skip-update]

Options:
  --run             Launch the built NovotroOpera binary after compiling.
  --no-skip-update  Force a full dependency-resolution build this run.
  --help            Show this help.

This script intentionally runs only:
  - swift build --product NovotroOpera -c debug [--disable-automatic-resolution]
It does not run tests or create/reinstall a release app bundle.
USAGE
}

while [[ "${1:-}" != "" ]]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --run)
            RUN_BINARY=true
            ;;
        --no-skip-update)
            SKIP_UPDATE=false
            ;;
        *)
            usage
            exit 1
            ;;
    esac
    shift
done

echo "=== Building Amira Writer (debug, local-only) ==="
cd "$PROJECT_DIR"

if [[ "$SKIP_UPDATE" == true ]]; then
    if ! swift build --product "$PRODUCT_NAME" -c "$CONFIG" --disable-automatic-resolution 2>&1; then
        echo "Dependency graph needs refresh; rebuilding with full resolution..."
        swift build --product "$PRODUCT_NAME" -c "$CONFIG" 2>&1
    fi
else
    swift build --product "$PRODUCT_NAME" -c "$CONFIG" 2>&1
fi

BINARY="$PROJECT_DIR/.build/$CONFIG/$PRODUCT_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "Binary: $BINARY"

if [[ "$RUN_BINARY" == true ]]; then
    echo "Launching $BINARY..."
    nohup "$BINARY" >/tmp/amira-writer-debug.log 2>&1 &
    echo "Launched. Log: /tmp/amira-writer-debug.log"
fi
