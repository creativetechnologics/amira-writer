# App Bundle Deployment Runbook

This is the canonical deployment path for the Swift/native Amira Writer app.

## The Rule

Gary tests the app from the packaged `.app` bundle, not from SwiftPM build products.

The only successful GUI deployment is:

```sh
/Volumes/Storage\ VIII/Programming/Amira\ Writer/Scripts/build-app.sh
```

That script must recreate:

```text
/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app
```

Do not report success until that bundle and its real executable have current timestamps.

## Why Agents Keep Getting Fooled

- `swift build -c release --product Opera` only updates `.build/release/Opera`.
- Xcode build products are not the app bundle Gary launches.
- The `.app` display name is `Amira Writer.app`, but the actual executable is `Contents/MacOS/Opera`.
- Checking `Contents/MacOS/Amira Writer` is wrong; that file should not be the proof point.
- Gary's laptop/MacBook launch synced copies from `~/Programming/!Applications`, so a server bundle may still need Syncthing time and a user relaunch before the device shows the new code.

## Correct Build And Verification

Run from the repo root:

```sh
cd "/Volumes/Storage VIII/Programming/Amira Writer"
"$PWD/Scripts/build-app.sh"
```

Then verify:

```sh
APP="/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
BIN="$APP/Contents/MacOS/Opera"

stat -f '%Sm %N' "$APP"
stat -f '%Sm %N' "$BIN"
shasum -a 256 "$BIN"
codesign --verify --deep --strict --verbose=2 "$APP"
```

Expected result:

- `stat` shows a current timestamp for both the bundle and `Contents/MacOS/Opera`.
- `shasum` prints the hash of the deployed executable, not the `.build` executable.
- `codesign --verify` exits successfully.

## If The Timestamp Is Still Old

Treat this as a failed deployment, even if SwiftPM said the build succeeded.

Check these in order:

```sh
APP="/Volumes/Storage VIII/Programming/!Applications/Amira Writer.app"
BIN="$APP/Contents/MacOS/Opera"

ls -ld "$APP"
ls -l "$BIN"
grep -n 'INSTALL_DIR\\|APP_NAME\\|APP_EXECUTABLE_NAME' Scripts/build-app.sh
```

The script should have:

```text
APP_EXECUTABLE_NAME="Opera"
APP_NAME="Amira Writer"
INSTALL_DIR="/Volumes/Storage VIII/Programming/!Applications"
```

If those are correct, rerun `Scripts/build-app.sh` and inspect its final `=== Installed:` line. Do not substitute another install location.

## Hard Boundaries

- Do not deploy to `~/Applications`, `/Applications`, Gary's laptop, or Gary's MacBook.
- Do not use the old `Novotro Write.app` path as proof.
- Do not quit, restart, relaunch, kill, or otherwise manipulate apps on Gary's laptop unless Gary explicitly approves it in the current session.
- Server-side app control is allowed only when needed for server-side validation.

## Reporting Proof

When reporting success, include:

- The deploy command used.
- The deployed bundle timestamp.
- The deployed `Contents/MacOS/Opera` timestamp.
- The deployed executable SHA-256 hash when practical.
- Whether code signing used Developer ID or stable ad-hoc fallback, if visible in the script output.
