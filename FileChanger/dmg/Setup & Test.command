#!/bin/bash
# Double-click to install FileChanger into Applications, start it, and run its self-test
# (the app's unit tests, its signature, and a launch check).
# FILECHANGER_INSTALL_DIR=<folder> installs somewhere else (used to test this script).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${FILECHANGER_INSTALL_DIR:-/Applications}"
[ -w "$DIR" ] || DIR="$HOME/Applications"
APP="$DIR/FileChanger.app"
BIN="$APP/Contents/MacOS/FileChanger"
LOG="$HOME/Library/Logs/FileChanger-SelfTest.log"
mkdir -p "$DIR" "$(dirname "$LOG")"

echo "Installing FileChanger into $DIR..."
pkill -f "^$BIN" 2>/dev/null && sleep 1   # quit only the copy being replaced
rm -rf "$APP" && ditto "$HERE/FileChanger.app" "$APP" || { echo "Install failed: could not copy into $DIR."; exit 1; }
# A downloaded image marks its files as quarantined, and Gatekeeper blocks a quarantined ad-hoc-signed app.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
open "$APP"

echo "Running FileChanger's unit tests (conversion, image, video/audio, menu bar). This takes a minute or two..."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/filechanger-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/Fixtures"
(cd "$WORK" && FILECHANGER_FIXTURES="$WORK/Fixtures" "$HERE/.support/FileChangerTests") >"$LOG" 2>&1
tests=$?
grep '^FAIL' "$LOG"

codesign --verify --deep --strict "$APP" 2>>"$LOG" && sign="ok" || sign="FAILED"
pgrep -f "^$BIN" >/dev/null && launch="ok (running in the menu bar)" || launch="FAILED"

cat <<EOF

================ FileChanger setup & self-test ================
Installed:   $APP
Unit tests:  $([ "$tests" -eq 0 ] && echo "passed" || echo "FAILED") ($(tail -1 "$LOG"))
Signature:   $sign
App launch:  $launch
Full log:    $LOG
===============================================================

Next:
  1. Allow FileChanger under System Settings > Privacy & Security > Accessibility when macOS asks
     (or use "Allow Wheel Shortcuts..." in its menu-bar menu). After installing a newer build,
     turn it off and on again: macOS ties the permission to the exact build.
  2. Drag a file from Finder and, while holding it, tap Shift (convert), Command (tools)
     or Control (actions). Drop on a petal. Originals are never changed.

More formats (MP3, Ogg, Opus, WebM, MKV, AVI, WebP...): brew install ffmpeg webp
Uninstall: quit FileChanger from its menu and move $APP to the Trash.

You can close this window.
EOF
[ "$tests" -eq 0 ] && [ "$sign" = ok ] && [ "$launch" != FAILED ]
