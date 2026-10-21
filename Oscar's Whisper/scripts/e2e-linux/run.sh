#!/usr/bin/env bash
# End-to-end check on Linux: runs the real app on a virtual X display, plays a speech recording
# into it through Chromium's fake microphone, drives it with synthetic key presses and clicks, and
# reads what got pasted into a separate text box. Needs: Xvfb, xdotool, xclip, python3 with
# tkinter, `npm install` and the speech model (`npm run fetch-model`).
# Usage: bash scripts/e2e-linux/run.sh   (from the "Oscar's Whisper" folder)
# Set PYTHON to a Python that has tkinter if the default python3 does not.
# Set OSCARS_WHISPER_BIN to a packaged executable (e.g. out/linux-unpacked/OscarsWhisper) to test
# the built app instead of the development copy.
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
# APP_PROCESS matches the app's processes (and its Chromium children) for cleanup. It must not
# be a prefix of other tools' paths: "node_modules/electron" would also match electron-builder.
if [ -n "${OSCARS_WHISPER_BIN:-}" ]; then
  LAUNCH=("$OSCARS_WHISPER_BIN")
  APP_PROCESS=$OSCARS_WHISPER_BIN
else
  LAUNCH=("$APP/node_modules/.bin/electron" .)
  APP_PROCESS=$APP/node_modules/electron/dist/
fi
[ -x "${LAUNCH[0]}" ] || { echo "FAIL: ${LAUNCH[0]} not found (run npm install first)"; exit 1; }
# The model's sample recording (7.4 s): "Well, I don't wish to see it any more, observed Phebe,
# turning away her eyes. It is certainly very like the old portrait." Every dictation starts at
# its beginning, so each paste contains "Well" exactly once.
SPEECH=${OSCARS_WHISPER_SPEECH_WAV:-$APP/models/parakeet-tdt-0.6b-v2-int8/test_wavs/0.wav}
[ -f "$SPEECH" ] || { echo "FAIL: $SPEECH not found (run npm run fetch-model)"; exit 1; }
LAUNCH+=(--no-sandbox --disable-gpu --use-fake-device-for-media-stream
  --use-fake-ui-for-media-stream "--use-file-for-fake-audio-capture=$SPEECH%noloop")

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

(cd "$APP" && OSCARS_WHISPER_DEBUG=1 exec "${LAUNCH[@]}") > "$OUT/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 120); do
  grep -qE "speech model (ready|failed)" "$OUT/app.log" 2> /dev/null && break
  sleep 0.5
done
grep -E "speech model (ready|failed)" "$OUT/app.log" || echo "(speech model not ready after 60 s)"
xdotool windowfocus --sync "$TARGET"

FAILURES=0
pastes() { grep -o "Well" "$OUT/target.txt" 2> /dev/null | wc -l; }
# wait_for_pastes N: wait up to 30 s for N pastes; prints how long the last one took.
wait_for_pastes() {
  local start=$SECONDS
  for _ in $(seq 150); do
    [ "$(pastes)" -ge "$1" ] && break
    sleep 0.2
  done
  echo "(waited $((SECONDS - start)) s for paste $1)"
  sleep 1 # let the clipboard be restored
}
# check LABEL EXPECTED_PASTE_COUNT: pastes so far, and the clipboard must be restored.
check() {
  local pastes clipboard
  pastes=$(pastes)
  clipboard=$(xclip -o -selection clipboard 2> /dev/null)
  if [ "$pastes" -eq "$2" ] && [ "$clipboard" = "ORIGINAL CLIPBOARD" ]; then
    echo "PASS: $1 (pastes=$pastes, clipboard restored)"
  else
    echo "FAIL: $1 (pastes=$pastes, expected $2; clipboard='$clipboard')"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "=== 1. hold Ctrl+Super through the whole recording (expect the full sentence pasted)"
xdotool keydown ctrl keydown super
sleep 8.5
xdotool keyup super keyup ctrl
wait_for_pastes 1
check "hold-to-talk" 1
words=$(tr -d '[:punct:]' < "$OUT/target.txt" | tr '[:upper:]' '[:lower:]')
for phrase in "i dont wish to see it any more" "very like the old portrait"; do
  if [[ "$words" == *"$phrase"* ]]; then
    echo "PASS: transcript contains \"$phrase\""
  else
    echo "FAIL: transcript lacks \"$phrase\": $(cat "$OUT/target.txt")"
    FAILURES=$((FAILURES + 1))
  fi
done

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
wait_for_pastes 2
check "bar click + re-press" 2

echo "=== 3. accidental 100 ms tap (expect nothing new pasted)"
xdotool keydown ctrl keydown super
sleep 0.1
xdotool keyup super keyup ctrl
sleep 2
check "accidental tap ignored" 2

echo "=== 4. launch a second copy (expect it to exit; one more hold then pastes only once)"
(cd "$APP" && OSCARS_WHISPER_DEBUG=1 exec "${LAUNCH[@]}") > "$OUT/second.log" 2>&1 &
SECOND_PID=$!
for _ in $(seq 100); do
  kill -0 "$SECOND_PID" 2> /dev/null || break
  sleep 0.1
done
# A copy that is still running is left alive, so the paste count below also catches it pasting.
if kill -0 "$SECOND_PID" 2> /dev/null; then
  echo "FAIL: second copy exited (still running after 10 s)"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: second copy exited"
fi
if grep -q "already running" "$OUT/second.log"; then
  echo "PASS: second copy logged 'already running'"
else
  echo "FAIL: second copy logged 'already running' (see $OUT/second.log)"
  FAILURES=$((FAILURES + 1))
fi
xdotool windowfocus --sync "$TARGET"
xdotool keydown ctrl keydown super
sleep 2
xdotool keyup super keyup ctrl
wait_for_pastes 3
sleep 2 # a second instance would paste later than the first
check "single instance: one paste per dictation" 3

echo "=== app log (notices and debug lines)"
grep -E '^\[oscars-whisper' "$OUT/app.log" | grep -v 'shape report'
echo "=== pasted text"
cat "$OUT/target.txt"
echo
echo "(full logs in $OUT)"

kill "$APP_PID" "$TARGET_PID" 2>/dev/null
pkill -f "$APP_PROCESS" 2>/dev/null
kill "$XVFB" 2>/dev/null
wait 2>/dev/null
[ "$FAILURES" -eq 0 ] && echo "ALL PASSED" || echo "$FAILURES FAILED"
exit "$FAILURES"
