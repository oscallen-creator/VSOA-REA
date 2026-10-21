# Oscar's Whisper

A minimal push-to-talk dictation app. Speak anywhere, and the text is pasted
into whatever app has focus. It covers four features:

- **Always-on button:** a small bar at the bottom of the screen. It stays above
  other windows and never steals focus.
- **Keyboard activation:** global hotkeys for hold-to-talk and hands-free.
- **Voice dictation:** 16 kHz mono microphone capture.
- **Cleanup and paste:** a placeholder AI step for transcription and cleanup
  (add your API key later), then a real paste into the focused app.

Its design follows what [REA](../README.md) recovered from Wispr Flow 1.6.1209's
decompiled Electron bundle (see [How it mirrors Wispr Flow](#how-it-mirrors-wispr-flow)).
The code is an independent rewrite. No Wispr code, assets, keys or endpoints are
included.

## Run it (Windows)

You need Node.js 22 or newer (24 recommended) and Git. In PowerShell:

```powershell
cd "Oscar's Whisper"
npm install
npm start
```

The first run asks for microphone access. If nothing records, open
**Settings → Privacy & security → Microphone** and turn on
**Let desktop apps access your microphone**.

## Use it

| Do this                           | What happens                                              |
| --------------------------------- | --------------------------------------------------------- |
| Hold **Ctrl+Win**, speak, release | Records while held, then transcribes and pastes           |
| Press **Ctrl+Win** twice quickly  | Locks hands-free mode; press again to stop                |
| **Ctrl+Win+Space**                | Toggles hands-free mode                                   |
| Click the bar                     | Starts hands-free; click the ■ to stop or the ✕ to cancel |
| **Esc** while recording           | Cancels                                                   |
| Right-click the bar               | Menu with **Quit**                                        |

On macOS the hotkeys are **Ctrl+Option** and **Ctrl+Option+Space**.

A tap shorter than half a second is treated as accidental and discarded.
Recordings stop automatically after 20 minutes, with a warning at 19.

## Add your API key later

All model calls are in [`src/main/pipeline/model.js`](src/main/pipeline/model.js):

- `transcribe()`: speech-to-text. It receives a 16 kHz mono 16-bit WAV.
- `cleanupWithModel()`: rewrites the raw transcript (punctuation,
  capitalization, filler words). Returning `null` falls back to the local rules
  in [`cleanup.js`](src/main/pipeline/cleanup.js).

Both are placeholders for now, marked with `TODO(api-key)`. Until they are
filled in, every dictation pastes
`This is a placeholder transcript of N seconds of audio`, which proves the
whole pipeline works.

Provide the key and model names with environment variables:

```powershell
$env:OSCARS_WHISPER_API_KEY = "..."
$env:OSCARS_WHISPER_TRANSCRIPTION_MODEL = "..."
$env:OSCARS_WHISPER_CLEANUP_MODEL = "..."
```

Or put them in `%APPDATA%\Oscar's Whisper\config.json`:

```json
{ "apiKey": "...", "transcriptionModel": "...", "cleanupModel": "..." }
```

The key is never logged. The same file can override hotkeys, for example
`"shortcuts": { "ctrl+win": "ptt" }`.

## How it mirrors Wispr Flow

| Feature       | What REA found in Wispr Flow                                                                                                                                                                                                                                | Oscar's Whisper                                                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always-on bar | Transparent, frameless, `alwaysOnTop` "screen-saver" window, 512 px wide, bottom-centred on the cursor's display. On Windows, `setShape` limits clicks to reported pill rectangles (≤128).                                                                  | Same window options and shape logic ([`flowbar/`](src/main/flowbar)). Pill sizes, colors, 10-bar waveform and spinner follow Wispr's states.       |
| Hotkeys       | A native helper streams raw key events. Electron matches held keys against bindings. Windows defaults are Ctrl+Win (hold) and Ctrl+Win+Space (hands-free).                                                                                                  | A global hook ([uiohook-napi](https://github.com/SnosMe/uiohook-napi)) feeds the same kind of held-key matcher ([`keyboard/`](src/main/keyboard)). |
| State machine | Initializing → Listening → Stopping → Processing. 500 ms debounce, double press locks hands-free, triple press dismisses, quick tap dismissed, 19/20-minute limits, dismiss after 5 s with no audio.                                                        | [`dictation/controller.js`](src/main/dictation/controller.js) implements the same rules.                                                           |
| Audio         | A hidden window captures 16 kHz mono with echo cancellation, noise suppression and auto-gain off. A worklet makes 640-sample (40 ms) chunks, converted to Int16 PCM. Leading silence is dropped. Bar level = dB above an adaptive floor, sent every 150 ms. | Same capture settings, chunking, PCM conversion and level meter ([`renderer/recorder/`](src/renderer/recorder), [`audio/`](src/main/audio)).       |
| Transcription | gRPC streaming to a hosted model while you speak, committed on release. The HTTP fallback uploads a 16 kHz mono WAV.                                                                                                                                        | Uploads one WAV at the end (placeholder call).                                                                                                     |
| Cleanup       | An LLM "format" step on the server. Local rules apply only to raw transcripts.                                                                                                                                                                              | The model call is the main cleanup step (placeholder). Simple local rules are the fallback.                                                        |
| Paste         | The helper writes the clipboard, sends Ctrl+V and restores the clipboard. On failure the text stays on the clipboard. Adds a trailing space at the end of text.                                                                                             | Same sequence, using Electron's clipboard and a simulated Ctrl+V. It also waits for hotkey modifiers to be released first.                         |

## Known differences and limits

- Wispr's native helper reads the text around the cursor for spacing and casing.
  Without it, this app always appends a trailing space and cannot match the
  surrounding text's capitalization.
- Only clipboard **text** is restored after a paste. An image on the clipboard is
  replaced.
- Transcription is one upload at the end rather than streaming while you speak.
- macOS needs Accessibility and Input Monitoring permission for the hotkeys and
  paste. The Fn-key defaults Wispr uses there are not supported.

## Development

```powershell
npm test   # 100 unit tests: key matcher, state machine, click-through shape, WAV, level meter
```

Set `OSCARS_WHISPER_DEBUG=1` to log bar input and clipboard decisions. Transcript
and clipboard text are never logged.

Verified so far:

- On Linux under a virtual X display with Chromium's fake microphone. Hold-to-talk
  pasted into another app and restored the clipboard. Bar click → hands-free →
  stop pasted. A quick tap was discarded.
- Not yet run on real Windows or macOS hardware.
