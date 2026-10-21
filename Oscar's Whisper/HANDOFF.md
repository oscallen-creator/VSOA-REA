# Oscar's Whisper: handoff

Everything done so far: what was built, how it was tested, what broke and was
fixed, and what still needs checking on a real Windows or Mac computer. All
work happened in a cloud Linux sandbox with no physical screen, microphone or
keyboard.

For install and everyday use, see [README.md](README.md).

## 1. Status at a glance

| Area                             | State                                                                                                                                                                                  |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always-on bar (button)           | Built. Clicks and states verified on a virtual Linux display.                                                                                                                          |
| Keyboard activation              | Built. Hold-to-talk, hands-free and accidental-tap rules verified with synthetic key presses.                                                                                          |
| Voice dictation (capture)        | Built. Verified with Chromium's fake microphone playing a speech recording, not a real mic.                                                                                            |
| Transcription                    | Built. Local Parakeet model (NVIDIA Parakeet TDT 0.6B v2, int8) run by sherpa-onnx: offline, English only. Verified with a recorded sentence on Linux and, for the engine, under Wine. |
| Cleanup                          | Local rules only (no LLM, by choice).                                                                                                                                                  |
| Paste into the focused app       | Built. Verified pasting into a separate app with the clipboard restored.                                                                                                               |
| Desktop app (installer)          | Built. The Windows installer (about 576 MB, includes the model) is verified under Wine only.                                                                                           |
| Single instance / start at login | Built. Start at login is not testable here.                                                                                                                                            |
| Unit tests                       | 142 passing (`npm test`).                                                                                                                                                              |
| End-to-end test                  | Real speech: all 4 scenarios pass from source and as a packaged Linux app (`scripts/e2e-linux/run.sh`).                                                                                |
| Real Windows / macOS             | **Not run yet.** See section 7.                                                                                                                                                        |

## 2. What was done, in order

1. **Prepared REA.**
   - Installed the pinned toolchain (Node 24.18.0, npm 11.16.0) and built REA.
   - Installed the free analysis tools and ran REA's own readiness checks plus
     27 real commands against small test files.
   - Setup commands were given separately. Wakaru 1.14.0 was added later
     because the decompile step needs it.
2. **Got the Wispr Flow code.**
   - The first upload was only a shortcut file. It pointed to
     `%LOCALAPPDATA%\WisprFlow\app-1.6.1209`.
   - Copying `resources/` failed because Wispr Flow was running and held a lock
     on `app.asar`. Closing it first fixed that.
   - The full copy was too large to upload, so a PowerShell script (tested
     first under PowerShell 7) pulled only Wispr's own code out of `app.asar`.
     That produced an 11.4 MB zip of 223 files.
3. **Decompiled it with REA.**
   - `analyze-javascript-application` worked on the smaller bundles. It ran out
     of memory on the 9.7 MB main bundle even with a 6 GB budget, and reported
     that as a limitation instead of a wrong result.
   - `recover-javascript-sources` (REA + Wakaru) turned the main bundle and the
     UI bundles into readable code: about 494,000 lines for the main process.
4. **Traced the five features.** I traced the window, hotkeys and state machine
   myself. Three agents traced the audio-to-transcription path, the cleanup and
   paste path, and the bar's UI. Their findings are summarized in the README's
   [How it mirrors Wispr Flow](README.md#how-it-mirrors-wispr-flow) table.
5. **Rewrote the features** as an independent Electron app in this folder.
6. **Tested.** An agent wrote the first 94 unit tests, which I extended to 100.
   I then ran the real app end to end on a virtual display. The runs found 4
   bugs (section 6), all fixed.
7. **Committed and pushed.** Three commits, now on `main`.
8. **Packaged as a desktop app.**
   - Added electron-builder 26.15.3 (pinned devDependency), the `npm run dist`
     scripts, an original app icon and a `build` config in `package.json`.
   - Built the Windows installer (`out/OscarsWhisper-Setup-0.1.0.exe`, about
     112 MB) on Linux with Wine 9.0. Checked the `.exe` resources and ran a silent
     install under Wine. The installed app started under Wine, then exited after
     about 8 s, as a bare Electron app does there. Real-Windows runtime is
     unverified.
   - In `src/main/index.js`: a single-instance lock and a **Start at login**
     checkbox in the bar's right-click menu.
   - Extended `scripts/e2e-linux/run.sh` with `OSCARS_WHISPER_BIN` and a 4th
     scenario (single instance). All 4 scenarios pass from source and as a
     packaged Linux app.
   - The macOS `.dmg` is configured but was not built or tested.
9. **Made speech-to-text real (local).**
   - Replaced the placeholder transcription with NVIDIA Parakeet TDT 0.6B v2 (int8
     ONNX export from the sherpa-onnx project), run by `sherpa-onnx-node` 1.13.8.
     It runs on the computer: no API key, no account, no network.
   - Chose no LLM cleanup. Removed `cleanupWithModel`, `src/main/pipeline/model.js`,
     the API-key settings and their environment variables, and WAV encoding
     (`src/main/audio/wav.js` and its 12 tests). The model takes float samples, so
     the new `src/main/audio/pcm.js` converts the recorder's 16-bit PCM.
   - Added `src/main/transcription/` (`speechModel.js`, `transcriber.js`,
     `chunking.js`), `scripts/fetch-model.mjs` and `THIRD_PARTY_NOTICES.md`. The
     model is downloaded at build time and bundled into the installer, which grew
     from about 112 MB to about 576 MB. `index.js` now passes `paste` into the
     pipeline, so the pipeline can be unit-tested.
   - Unit tests went from 100 to 142. The end-to-end script now plays real speech.
     Testing found 4 bugs (section 6), all fixed.
   - The Windows engine and the packaged `OscarsWhisper.exe` transcribed the sample
     under Wine. Real Windows was not available.
   - Wispr Flow streams audio to its own servers while you speak and formats it
     with a server-side LLM. Nothing of that runs in the Wispr client, so it could
     not be reused.

Not available to the analysis:

- Wispr's separate native helper (`Wispr Flow Helper.exe`). Its keyboard and
  paste behavior was inferred from how the main app talks to it.
- Wispr's servers. Server-side cleanup was inferred from the request and
  response formats.

## 3. Features as built

| Feature           | Behavior                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Always-on bar     | 512×96 transparent window, bottom-centre, 2 px above the work area. Always on top, never takes focus, follows the display under the cursor every 400 ms. Only the pill is clickable (`setShape` on Windows/Linux, mouse forwarding on macOS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Bar states        | Resting 40×8 → hover 50×30 mic button → push-to-talk 73×30 waveform → hands-free 102.5×30 with ✕ cancel and ■ stop → processing 98×30 spinner → error with a red border for 500 ms.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Waveform          | 10 bars. Each chunk's RMS is converted to dB above an adaptive floor (starts at −60 dB, only moves down). The average is sent every 150 ms and smoothed in the bar.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Hotkeys           | Windows/Linux: hold **Ctrl+Win** to talk, **Ctrl+Win+Space** hands-free, **Esc** cancels. macOS: **Ctrl+Option** variants. Left and right modifiers both work.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Timing rules      | 500 ms window: a second press locks hands-free, a third dismisses, and a tap shorter than 500 ms is discarded. Warning at 19 min, stop at 20 min. Dismissed if no audio arrives within 5 s. Nothing new starts while a transcript is processing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Capture           | Hidden window. 16 kHz mono, echo cancellation / noise suppression / auto-gain off. 640-sample (40 ms) chunks converted to Int16 PCM. Leading digital silence dropped. A 2 s safety net if the "done" signal is lost.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Speech-to-text    | Local, offline, English only. NVIDIA Parakeet TDT 0.6B v2 (int8 ONNX, from sherpa-onnx) run by `sherpa-onnx-node` 1.13.8 on min(4, CPU cores − 1) threads, at least 1. The model adds punctuation and capitalization itself. It loads once in the background at startup; a dictation that ends earlier waits for it, and a failed load is retried on the next dictation (the error says to run `npm run fetch-model`). Input under 0.5 s (`minInputSeconds` in `speechModel.js`) is not decoded and gives an empty transcript, because the model invents words ("Yeah.", "Mm-hmm.") for such input, even from silence. Recordings over 30 s are decoded in pieces of at most 30 s, cut at the quietest 100 ms in the last 5 s before each limit; the last piece is kept at least 1 s long, so a recording just over 30 s cannot end in a tiny piece that becomes "Yeah.". Measured: 30–60 s pieces decode fastest per second of audio, and past about 165 s in one piece the model drops capitals and punctuation. Silence, tones and noise of 1 s or longer return an empty transcript (tested up to 3 s). The model is fetched at build time by `npm run fetch-model` (482 MB download, pinned SHA-256, about 660 MB unpacked, git-ignored) and bundled into the installer under `resources/models/`.                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Pipeline          | PCM → float samples → local Parakeet → local tidy-up → paste. The tidy-up removes "um/uh/erm/hmm", fixes spacing, capitalizes the first letter and changes "i" to "I". There is no LLM step. If nothing is recognized (silence), nothing is pasted and the log says `nothing pasted: no_speech`. `index.js` passes `paste` into the pipeline, with the same clipboard save/paste/restore as before.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Paste             | Save clipboard text → write the transcript plus a trailing space → wait for Ctrl/Win/Alt/Shift to be released (up to 1 s) → wait 50 ms → send Ctrl+V (Cmd+V on macOS) → wait 600 ms → restore the old text unless something else changed the clipboard meanwhile.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Failure handling  | A failed paste leaves the text on the clipboard and flashes the bar red. Microphone errors end the dictation with an error notice.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Settings          | `%APPDATA%\Oscar's Whisper\config.json` reads only `shortcuts` (hotkey overrides), `pasteDelayMs` and `restoreClipboardDelayMs`. Other keys (for example an old `apiKey`) are ignored and never logged. A value of the wrong type is ignored with a warning, and the default is used. No setting uses an environment variable.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Diagnostics       | `OSCARS_WHISPER_DEBUG=1` logs bar input and clipboard decisions (lengths only, never text).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Install/packaging | electron-builder 26.15.3. `npm run dist` (current OS), `dist:win` (Windows x64 NSIS installer), `dist:mac` (`.dmg`), `dist:linux` (x64 AppImage). Output goes to `out/` (git-ignored). The Windows installer is one-click and per-user: no admin rights, installs to `%LOCALAPPDATA%\Programs\oscars-whisper`, adds "Oscar's Whisper" shortcuts to the Start menu and Desktop, launches the app when it finishes, and adds an uninstall entry (publisher "Oscar"). Uninstalling keeps `%APPDATA%\Oscar's Whisper\config.json`. The installer is not code-signed, so SmartScreen shows "Windows protected your PC" (**More info** → **Run anyway**). No auto-update (`"publish": null`). The speech model is bundled (`extraResources` → `resources/models/parakeet-tdt-0.6b-v2-int8/`: the `.onnx` files and `tokens.txt`), so the Windows installer is about 576 MB (was about 112 MB). `prestart` and every `predist*` script run `npm run fetch-model`, which does nothing once the model is in place (behind a proxy: set `HTTPS_PROXY` and `NODE_USE_ENV_PROXY=1`). Each platform's build includes only its own native engine package (`sherpa-onnx-win-x64` etc.). On Windows `npm install` fetches the Windows engine automatically; building the Windows installer from Linux or macOS needs the Windows package placed in `node_modules` too (npm installs only the host platform's), plus Wine. `THIRD_PARTY_NOTICES.md` is copied into the installed app's `resources` folder. New devDependencies for unpacking the model: `tar` 7.5.22 and `unbzip2-stream` 1.4.3. The macOS `.dmg` adds `NSMicrophoneUsageDescription` and `LSUIElement`, is unsigned, has no hardened runtime or notarization, and was not built or tested. |
| Single instance   | The app takes a single-instance lock. A second launch exits at once and logs `[oscars-whisper] already running; this copy exits`. A second copy would add a second key hook and microphone, so every dictation would be pasted twice.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Start at login    | A checkbox in the bar's right-click menu, above Quit. Off by default. Shown only in the installed app on Windows and macOS: in development it would register the bare Electron binary, and Electron has no login items on Linux.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

## 4. File map

| Path                                                          | Responsibility                                                                                                                                                                                                     |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/main/index.js`                                           | Startup and wiring: windows, key hook, state machine, level meter, bar IPC, right-click menu, single-instance lock, Start at login, background loading of the speech model; passes `paste` into the pipeline       |
| `src/main/constants.js`                                       | All timing and audio constants                                                                                                                                                                                     |
| `src/main/config.js`                                          | Settings loading: reads `shortcuts`, `pasteDelayMs`, `restoreClipboardDelayMs`; ignores other keys; type-checks values                                                                                             |
| `src/main/debug.js`                                           | Opt-in debug logging                                                                                                                                                                                               |
| `src/main/keyboard/keys.js`, `shortcutMatcher.js`             | Key names, default bindings, held-key matching                                                                                                                                                                     |
| `src/main/dictation/controller.js`                            | Dictation state machine                                                                                                                                                                                            |
| `src/main/flowbar/flowBarWindow.js`, `inputShape.js`          | Bar window and click-through shape                                                                                                                                                                                 |
| `src/main/audio/recorderBridge.js`, `pcm.js`, `levelMeter.js` | Recorder IPC, 16-bit PCM to float samples, waveform levels                                                                                                                                                         |
| `src/main/pipeline/pipeline.js`, `cleanup.js`, `paste.js`     | PCM → float → transcribe → local tidy-up → paste; `paste` is injected by `index.js`                                                                                                                                |
| `src/main/transcription/speechModel.js`                       | Model id, pinned download URL, SHA-256, file names, `minInputSeconds`                                                                                                                                              |
| `src/main/transcription/transcriber.js`                       | Owns the recognizer: loads the model once in the background, retries a failed load, skips input under 0.5 s, decodes in pieces                                                                                     |
| `src/main/transcription/chunking.js`                          | Splits recordings over 30 s at the quietest 100 ms near each limit; keeps the last piece at least 1 s                                                                                                              |
| `src/preload/*.mjs`                                           | The narrow bridges each window can use                                                                                                                                                                             |
| `src/renderer/flowbar/`                                       | Bar page (HTML/CSS/JS)                                                                                                                                                                                             |
| `src/renderer/recorder/`                                      | Hidden microphone page and audio worklet                                                                                                                                                                           |
| `src/shared/channels.js`                                      | IPC channel names                                                                                                                                                                                                  |
| `test/`                                                       | Unit tests (`support/controllerHarness.js` has the fake clock and recorder)                                                                                                                                        |
| `scripts/e2e-linux/`                                          | End-to-end test (Linux only); plays a speech recording through the fake microphone; can run against a packaged build                                                                                               |
| `scripts/fetch-model.mjs`                                     | Downloads the speech model, checks its pinned SHA-256, unpacks the needed files into `models/` (git-ignored). Runs before `npm start` and every `npm run dist*`                                                    |
| `models/`                                                     | The speech model, about 660 MB (git-ignored; created by `npm run fetch-model`)                                                                                                                                     |
| `THIRD_PARTY_NOTICES.md`                                      | Licenses of shipped components; also copied into the installed app's `resources` folder                                                                                                                            |
| `assets/icon.svg`, `assets/icon.png`                          | App icon: original artwork. The PNG is 1024×1024, rendered from the SVG                                                                                                                                            |
| `package.json` (`build` section)                              | electron-builder settings: app ID, executable name `OscarsWhisper`, icon, `"npmRebuild": false`, `"publish": null`, `extraResources` (model and notices), per-platform engine filters, Windows/macOS/Linux targets |
| `out/`                                                        | Installer output (git-ignored)                                                                                                                                                                                     |

## 5. Tests

### 5.1 Unit tests: `npm test` (142 passing)

These use Node's built-in test runner with a fake clock, so there are no real
waits. The exceptions are the 2 integration tests, which decode with the real
model and skip when it is not downloaded.

| File                              | Tests | Covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| --------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shortcutMatcher.test.js`         | 27    | Left/right modifier equivalence, either press order, auto-repeat ignored, exact matching, hands-free and Esc bindings, macOS defaults, stale-key sweep at the 60 s boundary, `reset()`, both-Ctrl-keys release                                                                                                                                                                                                                                                                  |
| `controller.test.js`              | 20    | Hold-to-talk start/stop, accidental-tap dismissal, double press locks, triple press dismisses, re-press stops, hands-free toggle and double-press dismiss, bar click stop, 500 ms boundaries                                                                                                                                                                                                                                                                                    |
| `controllerResilience.test.js`    | 11    | Busy guard while processing, recorder start failures and stale results, `stop()` after failure, no-audio dismissal at 5 s, 19-minute warning, 20-minute stop                                                                                                                                                                                                                                                                                                                    |
| `inputShape.test.js`              | 26    | Report validation (non-finite values, >512 rects, bad viewport), pixel snapping/clipping/sorting/deduping, 128-rect cap, sender and viewport checks, hidden shape after disable, no redundant `setShape`, mouse input only while a pill shape is applied                                                                                                                                                                                                                        |
| `levelMeter.test.js`              | 4     | dB conversion, 20 dB scaling and clamping, floor only moves down, averaging per update                                                                                                                                                                                                                                                                                                                                                                                          |
| `chunking.test.js`                | 15    | One piece when the input fits (empty and exact-limit input included); a split one sample over the limit; the default 30 s limit; pieces cover the input exactly, in order; cuts within 5 s of the limit; the last piece is kept at least 1 s; cuts at the centre of the quietest 100 ms, quietest over merely quiet, silence outside the search range ignored, search restarts from each cut; terminates on degenerate input, including a limit that rounds to 0 samples        |
| `pcm.test.js`                     | 5     | Scaling by 1/32768, low byte first, trailing odd byte ignored, empty or one-byte input, a Buffer at an odd offset                                                                                                                                                                                                                                                                                                                                                               |
| `config.test.js`                  | 8     | Defaults and file path with no file; known keys override; missing keys keep defaults; unknown keys such as an old API key dropped; wrong-typed value warned and ignored; non-object JSON; invalid JSON names the file; an unreadable file rejects                                                                                                                                                                                                                               |
| `pipeline.test.js`                | 6     | Under 200 ms is no audio and is not transcribed; Float32 samples reach the transcriber; tidy-up and trailing space on paste; empty or filler-only transcript is `no_speech` and not pasted; a failed paste throws and says the text is on the clipboard; a transcriber error propagates without pasting                                                                                                                                                                         |
| `transcriber.test.js`             | 18    | With a fake engine: recognizer config; model loaded once for repeated and concurrent calls; 1–4 threads by default; every missing model file named without loading the engine; retry after the files appear or the engine fails; concurrent callers share one failed attempt; float samples at 16 kHz and trimmed text; input under 0.5 s returns an empty transcript without loading the model; long input decoded in several streams and joined in order; empty texts skipped |
| `transcriber.integration.test.js` | 2     | The real model: transcribes its sample recording; returns an empty transcript for silence. Both skip when the model is not downloaded                                                                                                                                                                                                                                                                                                                                           |

The test agent also mutated the source about 70 ways to check that the tests
catch real changes. It added tests for every mutation that survived, except
three timer guards that can't be observed by any test. This mutation check was
done before speech-to-text was added.

### 5.2 End-to-end test: `PYTHON=python3.12 bash scripts/e2e-linux/run.sh`

The script runs the real app on a virtual X display (Xvfb) with Chromium's fake
microphone. It types with `xdotool` and pastes into a separate Tk text window.
The clipboard starts as `ORIGINAL CLIPBOARD`. It needs Xvfb, xdotool, xclip and
a Python with tkinter (set `PYTHON` if the default lacks it), plus the speech
model (`npm run fetch-model`). It checks its prerequisites and judges PASS/FAIL
itself.

The fake microphone now plays real speech: the model's sample recording
(`test_wavs/0.wav`, 7.4 s), "Well, I don't wish to see it any more, observed
Phebe, turning away her eyes. It is certainly very like the old portrait." The
script passes Chromium the flag
`--use-file-for-fake-audio-capture=<wav>%noloop`. The `%noloop` suffix plays the
file once instead of repeating it, so every dictation starts at the beginning of
the recording. Set `OSCARS_WHISPER_SPEECH_WAV` to use a different recording.

Transcription takes time, so the script waits for the speech model to load
(up to 60 s) and then waits for each paste (up to 30 s) instead of sleeping a
fixed time. It counts pastes by the word "Well", which each paste contains once.

By default it runs the app from source. Set
`OSCARS_WHISPER_BIN=/path/to/packaged/executable` to run the same scenarios
against a packaged build, for example `out/linux-unpacked/OscarsWhisper` from
`npx electron-builder --linux dir`.

| Scenario                                                 | Expected                                                                        | Result |
| -------------------------------------------------------- | ------------------------------------------------------------------------------- | ------ |
| Hold Ctrl+Super for the whole recording (8.5 s)          | One paste with the full sentence, clipboard restored                            | PASS   |
| Click bar (hands-free), then press the hotkey            | Second paste, clipboard restored                                                | PASS   |
| 100 ms tap                                               | Discarded, nothing pasted                                                       | PASS   |
| Single instance: launch a second copy, then hold-to-talk | Second copy exits with "already running"; hold-to-talk pastes exactly once more | PASS   |

Scenario 1 also checks the transcript text: after removing punctuation and
lowercasing, the paste must contain "i dont wish to see it any more" and "very
like the old portrait". Scenarios 2 and 4 record only the first seconds of the
file, so they paste only the start of the sentence. Pasted text from one run:
"Well, I don't wish to see it any more, observed Phebe, turning away her eyes. It
is certainly very like the old portrait. Well, I don't wish to see it any more.
Well, I don't wish to see it anymore."

Every scenario passed both from source and as a packaged app: the app built with
`npx electron-builder --linux dir` from the same code as the Windows installer, so
`app.asar` loading, the unpacked keyboard-hook binary and the recorder worklet
inside the archive all work when packaged. A negative control, with the
single-instance lock removed from a copy of the app, made scenario 4 fail
(`pastes=4`), so the scenario does detect a missing lock.

The script cleans up only the app's own processes (`APP_PROCESS`). An earlier
`node_modules/electron` pattern also matched, and killed, a running
`electron-builder`.

### 5.3 Static checks

REA's formatter and linter (`oxfmt`, `oxlint`) run on every commit through the
repo's hooks: 0 errors. There are two "function too long" warnings, both on
test `describe` blocks. The pre-push typecheck and lint passed.

In the packaging session the hooks were not installed in the sandbox, so `oxfmt
--check` and `oxlint` were run by hand on the changed files instead: no errors.

## 6. Bugs found by testing (all fixed)

| Bug                                                                | Found by                          | Cause                                                                                                                                           | Fix                                                                                     |
| ------------------------------------------------------------------ | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Bar could not be clicked                                           | End-to-end run                    | The shaped window was also told to ignore the mouse permanently. Wispr pairs that with a separate hit test, which had not been copied.          | The window takes input only while a pill shape is applied                               |
| Clipboard never restored                                           | End-to-end run plus debug log     | Electron 44's clipboard functions return Promises. The code treated them as plain values.                                                       | Await them                                                                              |
| Releasing one of two held Ctrl keys ended push-to-talk             | Test agent                        | Left and right Ctrl were merged before tracking held keys                                                                                       | Track physical keys; a key is released only when all its variants are up                |
| Consecutive dictations ran together                                | End-to-end run                    | No space between pastes                                                                                                                         | Trailing space, as Wispr adds when nothing follows the cursor                           |
| The chunker looped forever if the piece limit rounded to 0 samples | Test agent                        | A limit of 0 samples left each cut where the piece started, so the loop never moved forward. The app always uses 30 s, so the app never hit it. | Every piece has at least one sample, so every cut moves forward                         |
| `pipeline.js` could not be imported outside Electron               | Unit-testing the pipeline         | It imported `paste.js` directly, which needs Electron                                                                                           | `index.js` passes `paste` into the pipeline                                             |
| Config values were not type-checked                                | Unit-testing the settings         | A value of the wrong type was used as read from the file                                                                                        | Each value is validated; a wrong type is ignored with a warning and the default is used |
| Tiny last piece could be pasted as "Yeah."                         | Benchmark agent (short-clip scan) | The model invents words for input under about 0.5 s, and the chunker could leave a sub-second last piece                                        | Inputs under 0.5 s are skipped; the last piece is kept at least 1 s                     |

Also fixed: `npm test` used a form Node 24 rejects (`node --test test/`). An
early run of the end-to-end script reported nothing pasted because its target
window silently failed to start. The script now fails loudly instead.

## 7. Not tested here, and why

The sandbox is a Linux container with no physical screen, microphone, speakers
or keyboard, and no Windows or macOS. Everything below needs a real device.
Highest risk first:

| #   | What to check on your PC                                                                                                                                                | Why it couldn't be tested                                                                         | Risk if it's wrong                                              |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| 1   | `npm install` and `npm start` work on Windows (the folder name has an apostrophe and a space)                                                                           | No Windows                                                                                        | App won't start                                                 |
| 2   | Ctrl+Win is detected and does not open the Start menu or trigger Windows shortcuts                                                                                      | Synthetic X11 keys only; libuiohook on Windows uses a different hook                              | Hotkey doesn't work, or Windows reacts to it                    |
| 3   | A real microphone records: built-in, USB, Bluetooth headset                                                                                                             | Only Chromium's fake mic                                                                          | Silence; or the 5 s no-audio dismiss triggers                   |
| 4   | The microphone permission prompt and the Windows privacy setting                                                                                                        | No Windows privacy layer                                                                          | Nothing records                                                 |
| 5   | Paste into real apps: Notepad, Word, browser text boxes, Slack, VS Code                                                                                                 | Only a Tk text box                                                                                | Paste lands nowhere or in the wrong place                       |
| 6   | Apps running **as administrator**: Windows blocks a normal app from sending keys to them                                                                                | No Windows security boundaries                                                                    | No paste into admin windows (text stays on the clipboard)       |
| 7   | Terminals (Ctrl+V may not paste), remote desktop, games                                                                                                                 | Not available                                                                                     | No paste                                                        |
| 8   | Clicking the bar doesn't take focus away from the app you're typing in                                                                                                  | X11 without a window manager behaves differently from Windows                                     | Paste goes to the bar instead of your app                       |
| 9   | Bar position and click area on high-DPI displays (125%/150% scaling), multiple monitors, taskbar on the side or auto-hidden                                             | One virtual 1280×800 screen at 100%                                                               | Bar misplaced, or click area offset from the pill               |
| 10  | Transparent window looks right (no black box)                                                                                                                           | No compositor in the sandbox                                                                      | Cosmetic                                                        |
| 11  | Clipboard: Windows clipboard history (Win+V) and clipboard managers will record each transcript; images/files on the clipboard are replaced, not restored               | Text-only test                                                                                    | Privacy and convenience                                         |
| 12  | Slow apps that read the clipboard late (600 ms restore window)                                                                                                          | Not available                                                                                     | The old clipboard gets pasted                                   |
| 13  | Holding keys while the screen locks or the PC sleeps (stale-key sweep after 60 s)                                                                                       | Not available                                                                                     | A stuck "held" key until the sweep runs                         |
| 14  | Antivirus or SmartScreen warnings about a global keyboard hook                                                                                                          | Not available                                                                                     | App blocked or quarantined                                      |
| 15  | A full 20-minute recording (memory, warning, auto-stop on real time)                                                                                                    | Unit-tested with a fake clock only                                                                | Unexpected stop or memory use; about 38 MB of audio is held     |
| 16  | Hover/expand animation feel and waveform movement with real speech                                                                                                      | Not visible in the sandbox                                                                        | Cosmetic                                                        |
| 17  | **macOS:** Accessibility and Input Monitoring prompts, the Ctrl+Option hotkeys, the mouse-forwarding click path, panel window behavior                                  | No macOS                                                                                          | Hotkey, bar or paste doesn't work on Mac                        |
| 18  | Real microphone accuracy with your voice, accents and background noise                                                                                                  | Only one recorded English sentence was played through Chromium's fake microphone                  | Wrong or missing words                                          |
| 19  | Run `OscarsWhisper-Setup-0.1.0.exe`: SmartScreen shows "Windows protected your PC", **More info** → **Run anyway** works, and the install finishes without admin rights | Wine has no SmartScreen; only a silent install (`/S`) was run                                     | Installer blocked or install fails                              |
| 20  | The installed app starts from the Start menu shortcut and the Desktop shortcut, and hotkeys, microphone and paste work in it                                            | Under Wine it started, then exited after about 8 s, as a bare Electron app does there             | Installed app doesn't start, or exits                           |
| 21  | **Start at login** (right-click menu) survives a reboot: the app starts after you sign in and only one copy runs                                                        | Needs a real login session and reboot; the menu item is hidden in development                     | App doesn't start at login, or two copies run                   |
| 22  | Reinstalling or updating while the app is running: the installer asks you to close it, then updates in place. Uninstalling keeps `config.json`                          | Wine's `tasklist` makes the "app is running" check fail falsely, so the test build had it removed | Update fails, or the old copy keeps running                     |
| 23  | Transcription speed and RAM on your PC (weaker CPUs are slower)                                                                                                         | Measured only on a 4-core Linux container and under Wine                                          | Slow paste after you stop speaking, or memory pressure          |
| 24  | Model load time from a cold disk after a reboot (a dictation that ends sooner waits for the model)                                                                      | No cold-disk run on a real PC; the load times above are from a container                          | The first dictation after login is delayed                      |
| 25  | Antivirus scanning the larger installer (about 576 MB)                                                                                                                  | No Windows or antivirus here                                                                      | Slow or blocked download or install, or a quarantined installer |

To diagnose any of these, run with `$env:OSCARS_WHISPER_DEBUG = "1"; npm start`
and keep the console output.

## 8. Known limitations by design

- No cursor context. Wispr's helper reads the text around the cursor to fix
  casing, spacing and punctuation. This app always appends one trailing space
  and can't match the surrounding capitalization.
- Only clipboard text is restored.
- Transcription starts after you stop speaking. Wispr streams while you speak.
- English only.
- No Fn-key hotkeys on macOS.
- No Wispr extras: dictionary and snippets, command mode, "press enter",
  history, notes, meeting recorder, settings window.

## 9. Suggested next steps

1. Run section 7, items 1–9, on your Windows PC. Also run items 18 and 23–25 to
   check speech accuracy, speed, memory and load time with your voice. If you use
   the installer, also run items 19–22.
2. Optionally, decode while you speak (streaming) to lower the delay after you
   stop.
3. Optionally, try a multilingual model. Parakeet TDT 0.6B v3 (25 European
   languages) is a drop-in alternative: change the archive URL, SHA-256 and id in
   `src/main/transcription/speechModel.js`. It is not tested.
4. Optionally, add an LLM cleanup step later. The local tidy-up rules would stay
   as the default.
5. Optionally, what remains after packaging: code signing (the Windows installer
   and the macOS `.dmg` are unsigned), auto-update, and a settings window for
   hotkeys.

Note for future work: sherpa-onnx's `readWave()` cannot be used inside Electron
("External buffers are not allowed"). The app does not call it. It passes the
recorder's samples to the engine directly.

## 10. Provenance

- This is an independent rewrite based on behavior recovered with REA from
  Wispr Flow 1.6.1209, which you supplied from your own installation.
- No Wispr source code, assets, API keys or endpoints are included. A static
  model-host key found inside Wispr's bundle was deliberately left out.
- The decompiled Wispr files stayed in the temporary sandbox and were not
  committed.
- Icons are original simple SVGs, and the app icon (`assets/icon.svg`, rendered
  to `assets/icon.png`) is original artwork. Dependencies are Electron,
  [uiohook-napi](https://github.com/SnosMe/uiohook-napi) and `sherpa-onnx-node`
  1.13.8 (Apache-2.0, includes ONNX Runtime). electron-builder, `tar` and
  `unbzip2-stream` are devDependencies used only for packaging and for unpacking
  the model.
- The speech model is NVIDIA Parakeet TDT 0.6B v2 (CC-BY-4.0), in the int8 ONNX
  export published by the sherpa-onnx project. `npm run fetch-model` downloads it
  from the sherpa-onnx GitHub release `asr-models` at build time and checks the
  pinned SHA-256 (`157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad`).
  It is not committed. `THIRD_PARTY_NOTICES.md` lists the licenses.

## Appendix: REA environment work in the same session

- **REA doctor on a fresh Linux container:** Node OK. Hopper, Ghidra, IDA,
  JADX and Kuna were missing, and the agent registration and skill weren't
  installed. Ghidra 12.1.4 became healthy after a Nix install.
- **Commands checked against small test files** (content-verified):
  - native and binary: artifact inspection, ELF layout (pwntools), objdump,
    Rizin, Ghidra analyze/decompile/function/search/instructions,
    recorded-crash cores;
  - packages and data: Go binary, SQLite, safetensors model, WASM (WABT 1.0.42
    built from source), JavaScript/Electron app analysis, EVM bytecode;
  - captures and signals: pcap summary and TShark fields, sigrok UART decode;
  - firmware and processes: firmware extraction, process capture.
- **Ran, but proves little:** desktop-app inspection returned no runtime
  candidates. That is correct for a source folder, not an installed app.
- **Expected refusal:** Swift demangling needs macOS.
- **Upstream bug found:** Binwalk 3.1.0 sometimes exits before writing its
  report, about 7% of runs. It is a result-collection race in its main loop,
  still present upstream. REA correctly fails closed, but hides the cause.
  Workaround: retry `inspect-firmware-regions`.
- **Not completed:** the full REA test suite was stopped at your request after
  32 of 1,879 files, with no failures so far.
