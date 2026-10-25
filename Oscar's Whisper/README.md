# Oscar's Whisper

A minimal push-to-talk dictation app. Speak anywhere, and the text is pasted
into whatever app has focus. It covers four features:

- **Always-on button:** a small bar at the bottom of the screen. It stays above
  other windows and never steals focus.
- **Keyboard activation:** global hotkeys for hold-to-talk and hands-free.
- **Voice dictation:** 16 kHz mono microphone capture, turned into text on your
  computer by NVIDIA's Parakeet speech model. It works offline and adds
  punctuation and capitalization itself.
- **Cleanup and paste:** a few local tidy-up rules, then a real paste into the
  focused app.

Speech-to-text runs on your computer. There is no API key, no account, and no
internet needed after installing. Audio never leaves the computer.

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

   The installer is written to `out\OscarsWhisper-Setup-0.1.0.exe`. It is about
   576 MB because it includes the speech model. The `out/` folder is git-ignored.
   The first build downloads the model once (482 MB). `npm run dist:win` does this
   automatically, and later builds reuse it (see
   [Getting the model](#getting-the-model)). The build needs no C++ compiler or
   Visual Studio Build Tools.

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
  [Settings](#settings)).
- **Update.** After changing code, rebuild with `npm run dist:win` and run the new
  installer. It updates in place.
- **Uninstall.** Remove it under **Settings → Apps → Installed apps**.
  `%APPDATA%\Oscar's Whisper\config.json` is kept.
- **Works offline.** After installing, no internet is needed. For the first
  seconds after the app starts, it loads the speech model in the background (about
  3 s where measured). The bar works at once, and a dictation that ends sooner
  waits for the model. The app uses about 0.9 GB of memory with the model loaded,
  and about 1.1 GB at peak while decoding a 30 s piece (measured on Linux; see
  [Speed and memory](#speed-and-memory)).

If nothing records, see the microphone note in the next section. The installer
has been built, and installed under Wine on Linux, but it has not been run on
real Windows. See [Development](#development).

## Install it as a desktop app (macOS)

For Apple Silicon Macs (M1 and later). Tested on an M1 with macOS 15.

1. **Build the disk image.** You need Node.js 22 or newer and the Xcode Command
   Line Tools (`git` offers to install them the first time). In Terminal:

   ```bash
   cd "Oscar's Whisper"
   npm install
   npm run dist:mac
   ```

   The disk image is written to `out/OscarsWhisper-0.1.0-mac-arm64.dmg`, about
   613 MB because it includes the speech model. electron-builder refuses to sign
   an app whose output path contains an apostrophe, so `dist:mac` builds through a
   symlink without one (`$TMPDIR/oscars-whisper`) that points to this folder. The
   output still lands in `out/`.

2. **Install.** Open the `.dmg` and drag **OscarsWhisper** to **Applications**.
   The app is ad-hoc signed, not notarized. A `.dmg` you built yourself opens
   normally. A copy downloaded from the internet needs right-click → **Open** the
   first time, or `xattr -cr /Applications/OscarsWhisper.app`.

3. **Allow two permissions on first launch.**
   - **Microphone:** click **Allow** on the prompt.
   - **Accessibility,** for the hotkeys and the Cmd+V paste: turn on Oscar's
     Whisper under **System Settings → Privacy & Security → Accessibility**. The
     app keeps running while it waits, and the hotkeys work within about 2 s of
     granting. No restart is needed.

   macOS did not ask for Input Monitoring in testing. The signature is ad-hoc, so
   macOS ties the Accessibility grant to that exact build. After you install a
   rebuilt app, it waits for the permission again: select the old Oscar's Whisper
   entry under Accessibility, remove it with **−**, then turn on the new one. The
   microphone permission carries over.

Things to know about the installed app:

- **No Dock icon.** The bar is the app. Right-click it for **Start at login** and
  **Quit**.
- **Settings.** Use `~/Library/Application Support/Oscar's Whisper/config.json`
  (see [Settings](#settings)).
- **Logs.** Quit the app, then start it with logging into a file:

  ```bash
  open --env OSCARS_WHISPER_DEBUG=1 --stdout ~/oscars-whisper.log --stderr ~/oscars-whisper.log -a OscarsWhisper
  ```

  Starting `Contents/MacOS/OscarsWhisper` straight from Terminal also works, but
  then macOS asks for the permissions on Terminal's behalf, not the app's.
- **Uninstall.** Quit it, move `/Applications/OscarsWhisper.app` to the Trash,
  and remove it from the Accessibility and Microphone lists.

## Run it from source (development)

You need Node.js 22 or newer (24 recommended) and Git. In PowerShell:

```powershell
cd "Oscar's Whisper"
npm install
npm start
```

The first `npm start` downloads the speech model (482 MB) before the app opens.
Later starts skip that.

The first run asks for microphone access. If nothing records, open
**Settings → Privacy & security → Microphone** and turn on
**Let desktop apps access your microphone**.

On macOS, run the same commands in Terminal. Started from Terminal, macOS asks
for Microphone and Accessibility on Terminal's behalf (or your editor's), so allow
them there for development.

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

## Speech-to-text

Transcription runs on your computer. There is no API key, no account, and no
internet needed after installing. Audio never leaves the computer.

- **Model:** NVIDIA Parakeet TDT 0.6B v2, in the int8 ONNX export made by the
  sherpa-onnx project. The model adds punctuation and capitalization itself.
- **Engine:** [`sherpa-onnx-node`](https://github.com/k2-fsa/sherpa-onnx) 1.13.8
  (Apache-2.0), which includes ONNX Runtime. It uses min(4, CPU cores − 1)
  threads, and at least 1.
- **English only.** Parakeet TDT 0.6B v3 (25 European languages) is a drop-in
  alternative: change the archive URL, SHA-256 and id in
  [`speechModel.js`](src/main/transcription/speechModel.js). This is not tested.
- **Loading.** The model loads once, in the background, when the app starts. The
  bar works at once. A dictation that ends before the model is ready waits for
  it. If loading fails, the next dictation tries again, and the error says to run
  `npm run fetch-model`.
- **Long recordings.** A recording longer than 30 s is decoded in pieces of at
  most 30 s. Each piece is cut at the quietest 100 ms in the last 5 s before its
  limit, so cuts rarely split a word. The last piece is kept at least 1 s long,
  so a recording just over 30 s cannot end in a tiny piece that turns into
  "Yeah." In measurements, pieces of 30–60 s decode fastest per second of audio,
  and past about 165 s in a single piece Parakeet drops capitals and punctuation.
- **Silence and very short input.** For input shorter than about 0.5 s, Parakeet
  invents words ("Yeah.", "Mm-hmm."), even from pure silence. A recording under
  0.5 s is not decoded, and nothing is pasted. Silence, tones and noise of 1 s or
  longer give no text (tested up to 3 s). Whenever nothing is recognized, nothing
  is pasted and the log says `nothing pasted: no_speech`.
- **Tidy-up.** Simple local rules in
  [`cleanup.js`](src/main/pipeline/cleanup.js) run before the paste. There is no
  LLM step.
  - **Fillers:** "um", "uh", "erm" and "hmm" are dropped. "Like", "you know" and
    "I mean" are dropped only where Parakeet set them off with commas, as it does
    when you pause around them ("It was, like, really good, you know" → "It was
    really good."). Without the commas they stay, so "I like it" and "Do you know"
    are kept; a filler said without any pause stays too.
  - **Repeats:** stutters and false starts of up to three words are removed ("the
    the meeting", "I want to I want to go"). "had had" and "that that" are kept,
    and so are repeats with commas between them ("No, no, no").
  - **Spoken commands:** "new line" (or "line break"), "new paragraph", "comma",
    "question mark", "exclamation point" (or "mark") and "period" (or "full stop").
    Pause briefly around a command. "Period" counts only when you pause after it,
    so "the trial period ended" stays as words. A sentence that really ends in the
    word "period" loses it. A "new line" at the end pastes no trailing space.
  - Spacing is fixed, the first letter is capitalized and "i" becomes "I".

### Getting the model

The model is downloaded at build time and never committed. `npm run fetch-model`:

1. downloads a 482 MB `.tar.bz2` from the sherpa-onnx GitHub release `asr-models`
   (`sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2`);
2. checks its pinned SHA-256;
3. unpacks only the needed files into `models/parakeet-tdt-0.6b-v2-int8/`.

That folder is git-ignored and takes about 660 MB: `encoder.int8.onnx` (652 MB),
the decoder, the joiner, `tokens.txt`, and a sample recording, `test_wavs/0.wav`,
that the tests use.

It runs automatically before `npm start` and every `npm run dist*`, and does
nothing once the model is in place. In the Linux cloud container, download and
unpack took 2 min 10 s. Behind an HTTP proxy, set `HTTPS_PROXY` and
`NODE_USE_ENV_PROXY=1` first. The unpacking uses two devDependencies, `tar` 7.5.22
and `unbzip2-stream` 1.4.3.

### Speed and memory

These were measured on Linux (4 cores, a shared machine, best quiet runs), on
the Windows engine under Wine, and on an Apple M1 Mac (8 GB, macOS 15). They were
not measured on a real Windows PC. Your computer will differ, and weaker CPUs are
slower.

| What                                | Linux (Electron 44 main process)               | Windows engine under Wine | macOS, Apple M1                           |
| ----------------------------------- | ---------------------------------------------- | ------------------------- | ----------------------------------------- |
| Model load, in the background       | 2.9–3.3 s                                      | 3.2–6.9 s                 | 2.0 s in the installed app, 1.8 s in Node |
| Transcribing the 7.4 s sample       | 0.60–0.66 s with 4 threads                     | 0.8–0.9 s with 2 threads  | 0.28–0.40 s in Node, default threads      |
| Memory with the model loaded        | about 0.9 GB                                   | 0.9–1.5 GB while running  | 834 MB main process, 837 MB peak          |
| Memory, decoding one 30 s piece     | peaks at about 1.1 GB                          | not measured              | not measured                              |
| Event loop during loading, decoding | tick gaps of about 10–25 ms (stays responsive) | not measured              | not measured                              |

The Mac memory figure is the main process's physical footprint, which is what
Activity Monitor shows; the helper processes add about 0.1 GB. On the Mac, the
time from releasing the keys to the paste was not timed directly. It is the
transcription time above plus the 50 ms paste delay.

Noisy Linux runs took up to 3 s for the 7.4 s sample. Earlier runs in a 4-vCPU
Linux cloud container gave a 24 s recording in about 3.6 s, and in the
end-to-end test the text was pasted about 1 s after releasing the keys.

### Settings

`%APPDATA%\Oscar's Whisper\config.json` reads three keys:

- `shortcuts`: hotkey overrides, for example `"shortcuts": { "ctrl+win": "ptt" }`.
- `pasteDelayMs`: the wait between writing the clipboard and sending the paste
  keystroke (default 50).
- `restoreClipboardDelayMs`: the wait after the paste keystroke before restoring
  the old clipboard text (default 600).

Other keys, such as an `apiKey` left from an older version, are ignored and never
logged. A value of the wrong type is ignored with a warning, and the default is
used.

## Other platforms

Build output goes to `out/`. Each platform's build includes only its own native
speech engine package (for example `sherpa-onnx-win-x64`) and the speech model.

| Command              | Builds                           |
| -------------------- | -------------------------------- |
| `npm run dist`       | Installer for the current OS     |
| `npm run dist:win`   | Windows x64 NSIS installer       |
| `npm run dist:mac`   | macOS `.dmg` (build it on a Mac) |
| `npm run dist:linux` | Linux x64 AppImage               |

- **macOS:** Apple Silicon only (`--arm64`). See
  [Install it as a desktop app (macOS)](#install-it-as-a-desktop-app-macos). The
  config adds `NSMicrophoneUsageDescription` and `LSUIElement` (no Dock icon) and
  signs ad-hoc (`"identity": "-"`). Hardened runtime is off: with an ad-hoc
  signature it would reject Electron's frameworks and the speech engine's
  libraries, and it only matters for notarization, which needs a paid Developer
  ID.
- **Linux:** the packaged app passes the end-to-end test when built unpacked
  (`npx electron-builder --linux dir`). The AppImage wrapper itself was not run.

## How it mirrors Wispr Flow

| Feature       | What REA found in Wispr Flow                                                                                                                                                                                                                                | Oscar's Whisper                                                                                                                                                                                               |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always-on bar | Transparent, frameless, `alwaysOnTop` "screen-saver" window, 512 px wide, bottom-centred on the cursor's display. On Windows, `setShape` limits clicks to reported pill rectangles (≤128).                                                                  | Same window options and shape logic ([`flowbar/`](src/main/flowbar)). Pill sizes, colors, 10-bar waveform and spinner follow Wispr's states.                                                                  |
| Hotkeys       | A native helper streams raw key events. Electron matches held keys against bindings. Windows defaults are Ctrl+Win (hold) and Ctrl+Win+Space (hands-free).                                                                                                  | A global hook ([uiohook-napi](https://github.com/SnosMe/uiohook-napi)) feeds the same kind of held-key matcher ([`keyboard/`](src/main/keyboard)).                                                            |
| State machine | Initializing → Listening → Stopping → Processing. 500 ms debounce, double press locks hands-free, triple press dismisses, quick tap dismissed, 19/20-minute limits, dismiss after 5 s with no audio.                                                        | [`dictation/controller.js`](src/main/dictation/controller.js) implements the same rules.                                                                                                                      |
| Audio         | A hidden window captures 16 kHz mono with echo cancellation, noise suppression and auto-gain off. A worklet makes 640-sample (40 ms) chunks, converted to Int16 PCM. Leading silence is dropped. Bar level = dB above an adaptive floor, sent every 150 ms. | Same capture settings, chunking, PCM conversion and level meter ([`renderer/recorder/`](src/renderer/recorder), [`audio/`](src/main/audio)). The PCM is then converted to float samples for the speech model. |
| Transcription | gRPC streaming to a hosted model while you speak, committed on release. The HTTP fallback uploads a 16 kHz mono WAV.                                                                                                                                        | A local Parakeet model, run by sherpa-onnx after you stop speaking. No network.                                                                                                                               |
| Cleanup       | An LLM "format" step on the server. Local rules apply only to raw transcripts.                                                                                                                                                                              | No LLM. Parakeet adds punctuation and capitalization; local tidy-up rules only ([`cleanup.js`](src/main/pipeline/cleanup.js)).                                                                                |
| Paste         | The helper writes the clipboard, sends Ctrl+V and restores the clipboard. On failure the text stays on the clipboard. Adds a trailing space at the end of text.                                                                                             | Same sequence, using Electron's clipboard and a simulated Ctrl+V. It also waits for hotkey modifiers to be released first.                                                                                    |

Wispr's speech-to-text and formatting run on its servers, not in the Wispr client,
so none of that could be reused. Oscar's Whisper uses its own local model instead.

## Known differences and limits

- Wispr's native helper reads the text around the cursor for spacing and casing.
  Without it, this app always appends a trailing space and cannot match the
  surrounding text's capitalization.
- Only clipboard **text** is restored after a paste. An image on the clipboard is
  replaced.
- Transcription starts after you stop speaking. Wispr streams while you speak.
- English only.
- No LLM rewrite of the text.
- macOS needs Accessibility permission for the hotkeys and paste. The Fn-key
  defaults Wispr uses there are not supported.

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
npm test   # 178 unit tests: key matcher, state machine, click-through shape, level meter, PCM, chunking, settings, tidy-up, pipeline, transcriber
```

Two of the tests run the real model on its sample recording. They skip when the
model is not downloaded. The rest use a fake engine or no engine.

Set `OSCARS_WHISPER_DEBUG=1` to log bar input and clipboard decisions. Transcript
and clipboard text are never logged.

Packaging uses electron-builder 26.15.3, a pinned devDependency. Its settings are
in `package.json` under `"build"`:

- App ID `io.github.oscallen-creator.oscars-whisper` and executable name
  `OscarsWhisper` (no apostrophe in file names).
- Icon `assets/icon.png` (1024×1024), rendered from `assets/icon.svg`. Both are
  original artwork.
- `"npmRebuild": false`. uiohook-napi and sherpa-onnx ship prebuilt native
  binaries for each platform, so building needs no C++ compiler or Visual Studio
  Build Tools.
- `extraResources` copies the model's `.onnx` files and `tokens.txt` into
  `resources/models/parakeet-tdt-0.6b-v2-int8/`, and `THIRD_PARTY_NOTICES.md` into
  `resources`. The sample recording is not shipped.
- Each platform's build leaves out the other platforms' `sherpa-onnx-*` engine
  packages.
- `"publish": null`. There is no auto-update.

A second launch logs `[oscars-whisper] already running; this copy exits`.

Building the Windows installer from Linux or macOS needs Wine. It also needs the
Windows engine package (`sherpa-onnx-win-x64`) placed in `node_modules`, because
npm installs only the host platform's. On Windows, `npm install` fetches the
Windows engine automatically, so building there needs nothing extra.

Verified so far:

- On Linux under a virtual X display with Chromium's fake microphone, which plays
  the speech model's sample recording ("Well, I don't wish to see it any more,
  observed Phebe, turning away her eyes. It is certainly very like the old
  portrait."). Hold-to-talk through the whole recording pasted the full sentence
  into another app and restored the clipboard. Bar click → hands-free → stop
  pasted. A quick tap was discarded. A second launch exited and the next
  dictation pasted once. All of this passes both from source and as a packaged
  Linux app (`OSCARS_WHISPER_BIN`, see [HANDOFF.md](HANDOFF.md) section 5.2).
- `npm test`: 178 unit tests pass.
- The Windows installer built on Linux with electron-builder and Wine 9.0. It was
  about 112 MB before speech-to-text and is about 576 MB with the model. The next
  three checks were run on the earlier 112 MB build; this document does not
  record them for the 576 MB build. `OscarsWhisper.exe` has ProductName "Oscar's
  Whisper", CompanyName "Oscar", version 0.1.0, 7 embedded icon sizes, and no code
  signature. The packaged app contains `resources/app.asar` (the `src/` code and
  `package.json`) and
  `resources/app.asar.unpacked/node_modules/uiohook-napi/prebuilds/win32-x64/uiohook-napi.node`.
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
- Speech-to-text on Windows, under Wine only (no real Windows was available).
  The Windows engine (`sherpa-onnx-win-x64` 1.13.8) transcribed the sample
  exactly, both with Windows Node.js and with the packaged `OscarsWhisper.exe`
  run in Node mode. The packaged run loaded the app's own transcriber from inside
  `app.asar`, the native engine from `app.asar.unpacked` and the model from
  `resources/models` (load 3.2–6.9 s, transcription 0.8–0.9 s, over three runs
  including two of the final 576 MB build). The engine needs no
  Visual C++ runtime, because it is statically linked. On the container's Intel
  CPU, Wine sometimes crashed in ONNX Runtime's AMX instructions until worked
  around. That is a Wine limitation (Linux requires a permission call that Wine
  does not make), not expected on real Windows; AMX is mainly found on Intel Xeon
  CPUs. Electron's GUI still cannot run under Wine.
- On an Apple M1 Mac (macOS 15), with the `.dmg` built there and installed to
  `/Applications`: `codesign` reports `Signature=adhoc` and
  `codesign --verify --deep --strict` passes. On first launch the app asked for
  the microphone, then waited for Accessibility instead of quitting, and the
  hotkeys started within 2 s of granting it. With a real microphone and voice:
  hold-to-talk, Ctrl+Option+Space, Esc and the quick-tap rule behave as
  described, and the text pasted into TextEdit and every other app the owner
  tried, with the old clipboard text restored. Clicking the bar started
  hands-free without taking focus from TextEdit.
- Not tested: start at login, the bar over full-screen apps and on a second
  display on macOS, the Linux AppImage wrapper, and the installer's SmartScreen
  step.
- Not yet run on real Windows hardware. That includes the installer and the
  installed app.

## Credits and licenses

Oscar's Whisper ships Electron, uiohook-napi, sherpa-onnx (Apache-2.0, includes
ONNX Runtime) and the NVIDIA Parakeet TDT 0.6B v2 model (CC-BY-4.0). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the full list. The installed
app has a copy in its `resources` folder.
