#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_NAME="ProjectServiceApp"
APP_NAME="Project Service"
INSTALL_DIR="${PROJECT_SERVICE_INSTALL_DIR:-${NOVOTRO_INSTALL_DIR:-$HOME/Applications}}"
APP_BUNDLE="${INSTALL_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

BUILD_CONFIG="release"
for arg in "$@"; do
    case "$arg" in
        --debug) BUILD_CONFIG="debug" ;;
    esac
done

cd "$REPO_DIR"
swift build -c "$BUILD_CONFIG" --product "$TARGET_NAME"

BINARY_PATH="${REPO_DIR}/.build/${BUILD_CONFIG}/${TARGET_NAME}"
if [[ ! -x "$BINARY_PATH" ]]; then
    echo "error: built app binary not found at ${BINARY_PATH}" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$TARGET_NAME"
chmod +x "$MACOS_DIR/$TARGET_NAME"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.opera.projectservice</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${TARGET_NAME}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_BUNDLE"
echo "Built ${APP_BUNDLE}"
