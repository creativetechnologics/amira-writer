#!/usr/bin/env bash
set -euo pipefail

# Amira Writer build script
# Compiles with swift build, assembles .app bundle, code-signs, and installs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_EXECUTABLE_NAME="Opera"
APP_NAME="Amira Writer"          # Display name used for the .app bundle
BUNDLE_ID="com.amira.writer"
INSTALL_DIR="/Volumes/Storage VIII/Programming/!Applications"
# IMPORTANT: Never deploy to ~/Applications or remote machines.
# Only deploy to !Applications — the sync setup handles propagation.
LEGACY_LOCAL_APP="$INSTALL_DIR/Novotro Write.app"

# Parse arguments
BUILD_CONFIG="release"
SWIFT_FLAGS="-c release"
while [[ "${1:-}" != "" ]]; do
    case "$1" in
        --debug)
            BUILD_CONFIG="debug"
            SWIFT_FLAGS="-c debug"
            ;;
        --help)
            cat <<'USAGE'
Usage:
  build-app.sh [--debug]

Options:
  --debug       Build the debug configuration instead of release.
  --help        Show this help.
USAGE
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

find_suno_runtime_root() {
    local candidates=(
        "/Volumes/Storage VIII/Programming/SunoSkill"
        "/Volumes/Programming/SunoSkill"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/suno_cli/.venv" && -d "$candidate/suno_cli/src" && -d "$candidate/.ms-playwright" && -d "$candidate/python-installs" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

relative_path() {
    python3 - <<'PY' "$1" "$2"
import os
import sys

target = os.path.abspath(sys.argv[1])
start = os.path.abspath(sys.argv[2])
print(os.path.relpath(target, start))
PY
}

echo "=== Building $APP_NAME ($BUILD_CONFIG) ==="
echo "Install target: $INSTALL_DIR"

# 1. Build with swift build
cd "$PROJECT_DIR"
swift build $SWIFT_FLAGS --product "$APP_EXECUTABLE_NAME" 2>&1

resolve_binary() {
    local preferred="$PROJECT_DIR/.build/$BUILD_CONFIG/$APP_EXECUTABLE_NAME"
    if [[ -f "$preferred" ]]; then
        printf '%s' "$preferred"
        return 0
    fi
    return 1
}

BINARY="$(resolve_binary)" || {
    echo "ERROR: Binary not found at:"
    echo "  $PROJECT_DIR/.build/$BUILD_CONFIG/$APP_EXECUTABLE_NAME"
    exit 1
}
echo "Binary: $BINARY"

# 2. Assemble the .app bundle
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Remove old bundle
rm -rf "$APP_BUNDLE"

# Remove the previous app name from the user Applications folder.
if [[ -e "$LEGACY_LOCAL_APP" ]]; then
    rm -rf "$LEGACY_LOCAL_APP"
    echo "Removed legacy install: $LEGACY_LOCAL_APP"
fi

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy binary using the new preferred executable name.
cp "$BINARY" "$MACOS_DIR/$APP_EXECUTABLE_NAME"

# Copy Info.plist
if [[ -f "$PROJECT_DIR/Info.plist" ]]; then
    cp "$PROJECT_DIR/Info.plist" "$CONTENTS/Info.plist"
elif [[ -f "$PROJECT_DIR/Resources/Info.plist" ]]; then
    cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
else
    # Generate a minimal Info.plist
    cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST
fi

# Copy icon if present
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Copy SPM resource bundles (Metal shaders, 3D models, etc.)
BUILD_DIR="$PROJECT_DIR/.build/$BUILD_CONFIG"
for bundle in "$BUILD_DIR"/*.bundle; do
    if [[ -d "$bundle" ]]; then
        BUNDLE_NAME="$(basename "$bundle")"
        echo "Embedding resource bundle: $BUNDLE_NAME"
        cp -R "$bundle" "$RESOURCES_DIR/$BUNDLE_NAME"
    fi
done

# Copy helper scripts used by the installed app.
if [[ -f "$PROJECT_DIR/Scripts/gemini_inspiration_batch.py" ]]; then
    cp "$PROJECT_DIR/Scripts/gemini_inspiration_batch.py" "$RESOURCES_DIR/gemini_inspiration_batch.py"
fi

# Embed the 3D map pipeline viewer so the Places → 3D Map tab works even on
# machines without the dev server running. Source lives at
# `Scripts/3d-map-pipeline/viewer/` and was populated by
# `Scripts/3d-map-pipeline/run_all.sh` (phase F).
if [[ -d "$PROJECT_DIR/Scripts/3d-map-pipeline/viewer" ]]; then
    rm -rf "$RESOURCES_DIR/map3d-viewer"
    cp -R "$PROJECT_DIR/Scripts/3d-map-pipeline/viewer" "$RESOURCES_DIR/map3d-viewer"
    echo "Embedded 3D map viewer: $RESOURCES_DIR/map3d-viewer"
fi

# Embed the Suno CLI runtime so the synced app works on device-local machines
# without depending on a server-only absolute path.
SUNO_RUNTIME_ROOT="$(find_suno_runtime_root)" || {
    echo "ERROR: Could not find Suno runtime root in /Volumes/Storage VIII/Programming/SunoSkill or /Volumes/Programming/SunoSkill"
    exit 1
}
SUNO_BUNDLE_ROOT="$RESOURCES_DIR/SunoCLI"
SUNO_BUNDLE_CLI_ROOT="$SUNO_BUNDLE_ROOT/suno_cli"
SUNO_BUNDLE_VENV="$SUNO_BUNDLE_CLI_ROOT/.venv"
SUNO_BUNDLE_SITE_PACKAGES="$SUNO_BUNDLE_VENV/lib/python3.13/site-packages"

echo "Embedding Suno runtime from: $SUNO_RUNTIME_ROOT"
rm -rf "$SUNO_BUNDLE_ROOT"
mkdir -p "$SUNO_BUNDLE_CLI_ROOT"
ditto "$SUNO_RUNTIME_ROOT/.ms-playwright" "$SUNO_BUNDLE_ROOT/.ms-playwright"
rsync -a "$SUNO_RUNTIME_ROOT/python-installs" "$SUNO_BUNDLE_ROOT/"
rsync -a "$SUNO_RUNTIME_ROOT/suno_cli/src" "$SUNO_BUNDLE_CLI_ROOT/"
rsync -a "$SUNO_RUNTIME_ROOT/suno_cli/.venv" "$SUNO_BUNDLE_CLI_ROOT/"

EMBEDDED_PYTHON="$(find "$SUNO_BUNDLE_ROOT/python-installs" -maxdepth 3 -path '*/bin/python3' | head -1)"
if [[ -z "$EMBEDDED_PYTHON" ]]; then
    echo "ERROR: Bundled Suno runtime is missing python3 in $SUNO_BUNDLE_ROOT/python-installs"
    exit 1
fi

EMBEDDED_BIN_DIR="$SUNO_BUNDLE_VENV/bin"
EMBEDDED_PY_REL="$(relative_path "$EMBEDDED_PYTHON" "$EMBEDDED_BIN_DIR")"
rm -f "$EMBEDDED_BIN_DIR/python" "$EMBEDDED_BIN_DIR/python3" "$EMBEDDED_BIN_DIR/python3.13"
ln -s "$EMBEDDED_PY_REL" "$EMBEDDED_BIN_DIR/python"
ln -s python "$EMBEDDED_BIN_DIR/python3"
ln -s python "$EMBEDDED_BIN_DIR/python3.13"

if [[ -f "$SUNO_BUNDLE_SITE_PACKAGES/_editable_impl_suno_cli.pth" ]]; then
    printf '../../../../src\n' > "$SUNO_BUNDLE_SITE_PACKAGES/_editable_impl_suno_cli.pth"
fi

if ! PLAYWRIGHT_BROWSERS_PATH="$SUNO_BUNDLE_ROOT/.ms-playwright" \
    "$SUNO_BUNDLE_VENV/bin/suno" --json browser status >/dev/null; then
    echo "ERROR: Bundled Suno runtime smoke test failed"
    exit 1
fi
echo "Embedded Suno runtime: $SUNO_BUNDLE_ROOT"

# 3. Code sign
# Prefer Developer ID when available. If that fails or is unavailable, fall back
# to a stable ad-hoc signature with a fixed designated requirement so macOS TCC
# can keep recognizing the app across rebuilds.
SIGNING_IDENTITY="Developer ID Application: Creative Technologics LLC (9NHFC2GRXU)"
ADHOC_REQUIREMENT="designated => identifier \"$BUNDLE_ID\""

stable_adhoc_sign() {
    echo "Applying stable ad-hoc signature for $BUNDLE_ID"
    codesign \
        --force \
        --deep \
        --sign - \
        --identifier "$BUNDLE_ID" \
        -r="$ADHOC_REQUIREMENT" \
        "$APP_BUNDLE" 2>&1
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
    if ! codesign \
        --force \
        --deep \
        --timestamp \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE" 2>&1; then
        echo "Developer ID signing failed, falling back to stable ad-hoc signing"
        stable_adhoc_sign || echo "Warning: stable ad-hoc signing failed (non-fatal)"
    fi
else
    echo "Developer ID cert not found, falling back to stable ad-hoc signing"
    stable_adhoc_sign || echo "Warning: stable ad-hoc signing failed (non-fatal)"
fi

echo "=== Installed: $APP_BUNDLE ==="
echo "Done."
