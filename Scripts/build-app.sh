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
