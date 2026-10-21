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

## Install it as a desktop app (Windows)

This builds a normal Windows installer, so you can start Oscar's Whisper from the
Start menu instead of a terminal. If someone gave you a pre-built
`OscarsWhisper-Setup-0.1.0.exe`, skip step 1.

1. **Build the installer.** You need Node.js 22 or newer. In PowerShell:

   ```powershell
   cd "Oscar's Whisper"
   npm install
   npm run dist:win
   ```

   The installer is written to `out\OscarsWhisper-Setup-0.1.0.exe`. The `out/`
   folder is git-ignored. The build needs no C++ compiler or Visual Studio Build
   Tools.

2. **Run the installer.** It is not code-signed, so Windows SmartScreen shows
   **Windows protected your PC**. Click **More info**, then **Run anyway**.
   Antivirus may also flag the global keyboard hook.

The installer:

- needs no administrator rights and installs for your user only, into
  `%LOCALAPPDATA%\Programs\oscars-whisper`;
- creates "Oscar's Whisper" shortcuts in the Start menu and on the Desktop;
- starts the app when it finishes;
- adds an uninstall entry, "Oscar's Whisper 0.1.0" (publisher "Oscar"), under
  **Settings → Apps → Installed apps**.

Things to know about the installed app:

- **Start at login.** Right-click the bar and turn on **Start at login**. It is
  off by default.
- **One copy at a time.** If you open the app again while it is running, for
  example from the Start menu, the new copy exits at once. A second copy would add
  a second key hook and microphone, so every dictation would be pasted twice.
- **Settings.** Use `%APPDATA%\Oscar's Whisper\config.json` (see
  [Add your API key later](#add-your-api-key-later)).
- **Update.** After changing code, rebuild with `npm run dist:win` and run the new
  installer. It updates in place.
- **Uninstall.** Remove it under **Settings → Apps → Installed apps**.
  `%APPDATA%\Oscar's Whisper\config.json` is kept.
- **Placeholders.** Transcription and cleanup are still placeholders, so the
  installed app pastes the placeholder transcript until you fill them in.

If nothing records, see the microphone note in the next section. The installer
has been built, and installed under Wine on Linux, but it has not been run on
real Windows. See [Development](#development).

## Run it from source (development)

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

| Do this                                  | What happens                                                         |
| ---------------------------------------- | -------------------------------------------------------------------- |
| Hold **Ctrl+Win**, speak, release        | Records while held, then transcribes and pastes                      |
| Press **Ctrl+Win** twice quickly         | Locks hands-free mode; press again to stop                           |
| **Ctrl+Win+Space**                       | Toggles hands-free mode                                              |
| Click the bar                            | Starts hands-free; click the ■ to stop or the ✕ to cancel            |
| **Esc** while recording                  | Cancels                                                              |
| Right-click the bar → **Start at login** | Starts the app when you sign in (installed app only; off by default) |
| Right-click the bar → **Quit**           | Quits the app                                                        |

On macOS the hotkeys are **Ctrl+Option** and **Ctrl+Option+Space**.

**Start at login** is shown only in the installed app on Windows and macOS. In
development it would register the bare Electron binary, and Electron has no login
items on Linux.

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

Variables set with `$env:OSCARS_WHISPER_...` in a PowerShell window only apply to
apps started from that window. They do not reach the installed app when you start
it from the Start menu, the Desktop shortcut or at login. For the installed app,
use `config.json`, or set persistent user environment variables with `setx` and
restart the app. After changing code, rebuild with `npm run dist:win` and run the
new installer.

The key is never logged. The same file can override hotkeys, for example
`"shortcuts": { "ctrl+win": "ptt" }`.

## Other platforms

Build output goes to `out/`.

| Command              | Builds                           |
| -------------------- | -------------------------------- |
| `npm run dist`       | Installer for the current OS     |
| `npm run dist:win`   | Windows x64 NSIS installer       |
| `npm run dist:mac`   | macOS `.dmg` (build it on a Mac) |
| `npm run dist:linux` | Linux x64 AppImage               |

- **macOS:** the config adds `NSMicrophoneUsageDescription` and `LSUIElement` (no
  Dock icon). The `.dmg` is unsigned and was **not built or tested**. On first
  open, use right-click → **Open**. Hardened runtime and notarization are not
  configured.
- **Linux:** the packaged app passes the end-to-end test when built unpacked
  (`npx electron-builder --linux dir`). The AppImage wrapper itself was not run.

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

See [HANDOFF.md](HANDOFF.md) for everything tested, bugs found, and the
checklist of things still to verify on a real Windows or Mac computer.

## Working on only this folder

Git commits always snapshot the whole repository, but you do not need to download
all of it. A partial clone with sparse checkout fetches only this folder (plus the
top-level files) and still pushes normally:

```powershell
git clone --filter=blob:none --sparse https://github.com/oscallen-creator/VSOA-REA.git
cd VSOA-REA
git sparse-checkout set "Oscar's Whisper"
```

## Development

```powershell
npm test   # 100 unit tests: key matcher, state machine, click-through shape, WAV, level meter
```

Set `OSCARS_WHISPER_DEBUG=1` to log bar input and clipboard decisions. Transcript
and clipboard text are never logged.

Packaging uses electron-builder 26.15.3, a pinned devDependency. Its settings are
in `package.json` under `"build"`:

- App ID `io.github.oscallen-creator.oscars-whisper` and executable name
  `OscarsWhisper` (no apostrophe in file names).
- Icon `assets/icon.png` (1024×1024), rendered from `assets/icon.svg`. Both are
  original artwork.
- `"npmRebuild": false`. uiohook-napi ships prebuilt N-API binaries for Windows,
  macOS and Linux on x64 and arm64, so building needs no C++ compiler or Visual
  Studio Build Tools.
- `"publish": null`. There is no auto-update.

A second launch logs `[oscars-whisper] already running; this copy exits`.

Building the Windows installer from Linux or macOS needs Wine. Building it on
Windows needs nothing extra.

Verified so far:

- On Linux under a virtual X display with Chromium's fake microphone. Hold-to-talk
  pasted into another app and restored the clipboard. Bar click → hands-free →
  stop pasted. A quick tap was discarded. A second launch exited and the next
  dictation pasted once. All of this passes both from source and as a packaged
  app (`OSCARS_WHISPER_BIN`, see [HANDOFF.md](HANDOFF.md) section 5.2).
- `npm test`: 100 of 100 unit tests pass.
- The Windows installer (about 112 MB) built on Linux with electron-builder and
  Wine 9.0. `OscarsWhisper.exe` has ProductName "Oscar's Whisper", CompanyName
  "Oscar", version 0.1.0, 7 embedded icon sizes, and no code signature. The
  packaged app contains `resources/app.asar` (the `src/` code and `package.json`)
  and `resources/app.asar.unpacked/node_modules/uiohook-napi/prebuilds/win32-x64/uiohook-napi.node`.
- Under Wine, a silent install (`/S`) put the app in
  `%LOCALAPPDATA%\Programs\oscars-whisper` and created both shortcuts and the
  uninstall entry. Wine's `tasklist` makes the installer's "app is running" check
  give a false positive, so this test used a build with that check removed. The
  shipped installer keeps the check.
- Under Wine, the installed app started: the main process ran, loaded the
  settings path and the keyboard-hook module, and the bar page rendered. It then
  exited (code 3) after about 8 seconds. A bare Electron 44 app with no app code
  exits the same way under Wine, so this is a Wine limitation. It says nothing
  about real Windows.
- Not tested: start at login, the macOS `.dmg`, the Linux AppImage wrapper, and
  the installer's SmartScreen step.
- Not yet run on real Windows or macOS hardware. That includes the installer and
  the installed app.
