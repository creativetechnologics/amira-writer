#!/usr/bin/env bash
set -euo pipefail

# Amira Writer build script
# Compiles with swift build, assembles .app bundle, code-signs, and installs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_NAME="NovotroOpera"      # Swift target name / binary name (no spaces)
APP_NAME="Amira Writer"         # Display name used for the .app bundle
BUNDLE_ID="com.novotro.amirawriter"
INSTALL_DIR="/Volumes/Storage VIII/Programming/!Applications"
LEGACY_SYSTEM_APP="/Applications/$APP_NAME.app"
LEGACY_LOCAL_APP="$INSTALL_DIR/Novotro Write.app"
REMOTE_USER="gary"
REMOTE_INSTALL_DIR="/Users/$REMOTE_USER/Applications"
REMOTE_HOSTS=(
    "Garys-Laptop.local"
    "Garys-MacBook.local"
)
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

normalize_host() {
    printf '%s' "${1%%.*}" | tr '[:upper:]' '[:lower:]'
}

CURRENT_HOST="$(hostname)"
DEPLOY_REMOTES=false
SSH_CMD=(ssh)
SCP_CMD=(scp)

if [[ -f "$SSH_KEY_PATH" ]]; then
    SSH_CMD+=( -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes )
    SCP_CMD+=( -i "$SSH_KEY_PATH" -o IdentitiesOnly=yes )
fi

# Parse arguments
BUILD_CONFIG="release"
SWIFT_FLAGS="-c release"
while [[ "${1:-}" != "" ]]; do
    case "$1" in
        --debug)
            BUILD_CONFIG="debug"
            SWIFT_FLAGS="-c debug"
            ;;
        --local-only)
            DEPLOY_REMOTES=false
            ;;
        --help)
            cat <<'USAGE'
Usage:
  build-app.sh [--debug] [--local-only]

Options:
  --debug       Build the debug configuration instead of release.
  --local-only  Skip remote deployment after the local app bundle is installed.
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
swift build $SWIFT_FLAGS 2>&1

# Locate the built binary
BINARY="$PROJECT_DIR/.build/$BUILD_CONFIG/$TARGET_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi
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

# Copy binary (named after the target inside the bundle)
cp "$BINARY" "$MACOS_DIR/$TARGET_NAME"

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
    <string>$TARGET_NAME</string>
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

# 3. Ad-hoc code sign
codesign --force --sign - "$APP_BUNDLE" 2>&1 || echo "Warning: code signing failed (non-fatal)"

# 4. Remove legacy system-wide install if it exists.
if [[ -e "$LEGACY_SYSTEM_APP" ]]; then
    rm -rf "$LEGACY_SYSTEM_APP"
    echo "Removed legacy install: $LEGACY_SYSTEM_APP"
fi

echo "=== Installed: $APP_BUNDLE ==="

if [[ "$DEPLOY_REMOTES" == true ]]; then
    echo "Deploying to remote user Applications folders..."
    failed_hosts=()
    for remote_host in "${REMOTE_HOSTS[@]}"; do
        if [[ "$(normalize_host "$remote_host")" == "$(normalize_host "$CURRENT_HOST")" ]]; then
            echo "Skipping $remote_host (current host already has local install)."
            continue
        fi

        remote_target="$REMOTE_USER@$remote_host"
        remote_app_bundle="$REMOTE_INSTALL_DIR/${APP_NAME// /\\ }.app"
        echo "-> $remote_target:$REMOTE_INSTALL_DIR"
        if ! "${SSH_CMD[@]}" "$remote_target" "mkdir -p $REMOTE_INSTALL_DIR && rm -rf $remote_app_bundle"; then
            failed_hosts+=("$remote_host (prepare)")
            continue
        fi
        if ! "${SCP_CMD[@]}" -r "$APP_BUNDLE" "$remote_target:$REMOTE_INSTALL_DIR/"; then
            failed_hosts+=("$remote_host (copy)")
            continue
        fi
        if ! "${SSH_CMD[@]}" "$remote_target" "codesign --force --sign - --deep $remote_app_bundle"; then
            failed_hosts+=("$remote_host (codesign)")
            continue
        fi
        echo "   deployed successfully"
    done

    if (( ${#failed_hosts[@]} > 0 )); then
        echo "Remote deployment failures:"
        printf ' - %s\n' "${failed_hosts[@]}"
        exit 1
    fi
fi

echo "Done."
