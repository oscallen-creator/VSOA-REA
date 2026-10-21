#!/usr/bin/env bash
# End-to-end check on Linux: runs the real app on a virtual X display with Chromium's fake
# microphone, drives it with synthetic key presses and clicks, and reads what got pasted into
# a separate text box. Needs: Xvfb, xdotool, xclip, python3 with tkinter, and `npm install` done.
# Usage: bash scripts/e2e-linux/run.sh   (from the "Oscar's Whisper" folder)
# Set PYTHON to a Python that has tkinter if the default python3 does not.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APP=$(cd "$HERE/../.." && pwd)
PYTHON=${PYTHON:-python3}
OUT=$(mktemp -d)
export DISPLAY=:99

for tool in Xvfb xdotool xclip "$PYTHON"; do
  command -v "$tool" > /dev/null || { echo "FAIL: missing $tool"; exit 1; }
done
"$PYTHON" -c "import tkinter" 2> /dev/null ||
  { echo "FAIL: $PYTHON has no tkinter; set PYTHON=/path/to/python-with-tk"; exit 1; }
[ -x "$APP/node_modules/.bin/electron" ] || { echo "FAIL: run npm install first"; exit 1; }

Xvfb :99 -screen 0 1280x800x24 > "$OUT/xvfb.log" 2>&1 &
XVFB=$!
sleep 1

"$PYTHON" "$HERE/paste_target.py" "$OUT/target.txt" > "$OUT/target.log" 2>&1 &
TARGET_PID=$!
sleep 1.5
TARGET=$(xdotool search --name "^paste-target$" | head -1)
if [ -z "$TARGET" ]; then
  echo "FAIL: paste target window did not open (see $OUT/target.log)"
  kill "$XVFB" 2> /dev/null
  exit 1
fi
xdotool windowfocus --sync "$TARGET"
printf 'ORIGINAL CLIPBOARD' | xclip -selection clipboard

(cd "$APP" && OSCARS_WHISPER_DEBUG=1 exec ./node_modules/.bin/electron . --no-sandbox \
  --disable-gpu --use-fake-device-for-media-stream --use-fake-ui-for-media-stream) \
  > "$OUT/app.log" 2>&1 &
APP_PID=$!
sleep 6
xdotool windowfocus --sync "$TARGET"

FAILURES=0
# check LABEL EXPECTED_PASTE_COUNT: pastes so far, and the clipboard must be restored.
check() {
  local pastes clipboard
  pastes=$(grep -o "placeholder transcript" "$OUT/target.txt" 2> /dev/null | wc -l)
  clipboard=$(xclip -o -selection clipboard 2> /dev/null)
  if [ "$pastes" -eq "$2" ] && [ "$clipboard" = "ORIGINAL CLIPBOARD" ]; then
    echo "PASS: $1 (pastes=$pastes, clipboard restored)"
  else
    echo "FAIL: $1 (pastes=$pastes, expected $2; clipboard='$clipboard')"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== 1. hold Ctrl+Super for 2 s (expect a paste, clipboard restored)"
xdotool keydown ctrl keydown super
sleep 2
xdotool keyup super keyup ctrl
sleep 3
check "hold-to-talk" 1

echo "=== 2. click the bar (hands-free), then press the hotkey again to stop (expect a 2nd paste)"
# The pill sits bottom-centre: window 512x96 at the bottom of a 1280x800 screen.
xdotool mousemove 640 780
sleep 0.5
xdotool click 1
sleep 2
xdotool windowfocus --sync "$TARGET"
xdotool keydown ctrl keydown super
sleep 0.2
xdotool keyup super keyup ctrl
sleep 3
check "bar click + re-press" 2

echo "=== 3. accidental 100 ms tap (expect nothing new pasted)"
xdotool keydown ctrl keydown super
sleep 0.1
xdotool keyup super keyup ctrl
sleep 2
check "accidental tap ignored" 2

echo "=== app log (notices and debug lines)"
grep -E '^\[oscars-whisper' "$OUT/app.log" | grep -v 'shape report'
echo "(full logs in $OUT)"

kill "$APP_PID" "$TARGET_PID" 2>/dev/null
pkill -f "$APP/node_modules/electron" 2>/dev/null
kill "$XVFB" 2>/dev/null
wait 2>/dev/null
[ "$FAILURES" -eq 0 ] && echo "ALL PASSED" || echo "$FAILURES FAILED"
exit "$FAILURES"
