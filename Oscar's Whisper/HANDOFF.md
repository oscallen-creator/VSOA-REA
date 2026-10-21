# Oscar's Whisper: handoff

Everything done so far: what was built, how it was tested, what broke and was
fixed, and what still needs checking on a real Windows or Mac computer. All
work happened in a cloud Linux sandbox with no physical screen, microphone or
keyboard.

For install and everyday use, see [README.md](README.md).

## 1. Status at a glance

| Area                       | State                                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| Always-on bar (button)     | Built. Clicks and states verified on a virtual Linux display.                                 |
| Keyboard activation        | Built. Hold-to-talk, hands-free and accidental-tap rules verified with synthetic key presses. |
| Voice dictation (capture)  | Built. Verified with Chromium's fake microphone, not a real one.                              |
| Transcription              | **Placeholder.** Returns `um this is a placeholder transcript of N seconds of audio`.         |
| Cleanup                    | **Placeholder model call** plus working local fallback rules.                                 |
| Paste into the focused app | Built. Verified pasting into a separate app with the clipboard restored.                      |
| Unit tests                 | 100 passing (`npm test`).                                                                     |
| End-to-end test            | All 3 scenarios pass (`scripts/e2e-linux/run.sh`, Linux only).                                |
| Real Windows / macOS       | **Not run yet.** See section 7.                                                               |

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

Not available to the analysis:

- Wispr's separate native helper (`Wispr Flow Helper.exe`). Its keyboard and
  paste behavior was inferred from how the main app talks to it.
- Wispr's servers. Server-side cleanup was inferred from the request and
  response formats.

## 3. Features as built

| Feature          | Behavior                                                                                                                                                                                                                                                          |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Always-on bar    | 512×96 transparent window, bottom-centre, 2 px above the work area. Always on top, never takes focus, follows the display under the cursor every 400 ms. Only the pill is clickable (`setShape` on Windows/Linux, mouse forwarding on macOS).                     |
| Bar states       | Resting 40×8 → hover 50×30 mic button → push-to-talk 73×30 waveform → hands-free 102.5×30 with ✕ cancel and ■ stop → processing 98×30 spinner → error with a red border for 500 ms.                                                                               |
| Waveform         | 10 bars. Each chunk's RMS is converted to dB above an adaptive floor (starts at −60 dB, only moves down). The average is sent every 150 ms and smoothed in the bar.                                                                                               |
| Hotkeys          | Windows/Linux: hold **Ctrl+Win** to talk, **Ctrl+Win+Space** hands-free, **Esc** cancels. macOS: **Ctrl+Option** variants. Left and right modifiers both work.                                                                                                    |
| Timing rules     | 500 ms window: a second press locks hands-free, a third dismisses, and a tap shorter than 500 ms is discarded. Warning at 19 min, stop at 20 min. Dismissed if no audio arrives within 5 s. Nothing new starts while a transcript is processing.                  |
| Capture          | Hidden window. 16 kHz mono, echo cancellation / noise suppression / auto-gain off. 640-sample (40 ms) chunks converted to Int16 PCM. Leading digital silence dropped. A 2 s safety net if the "done" signal is lost.                                              |
| Pipeline         | PCM → WAV → `transcribe()` → `cleanupWithModel()`. If that returns `null`, local rules apply: remove "um/uh/erm/hmm", tidy spaces, capitalize. Then paste.                                                                                                        |
| Paste            | Save clipboard text → write the transcript plus a trailing space → wait for Ctrl/Win/Alt/Shift to be released (up to 1 s) → wait 50 ms → send Ctrl+V (Cmd+V on macOS) → wait 600 ms → restore the old text unless something else changed the clipboard meanwhile. |
| Failure handling | A failed paste leaves the text on the clipboard and flashes the bar red. Microphone errors end the dictation with an error notice.                                                                                                                                |
| Settings         | `OSCARS_WHISPER_API_KEY`, `..._TRANSCRIPTION_MODEL`, `..._CLEANUP_MODEL`, or `%APPDATA%\Oscar's Whisper\config.json` (also hotkey overrides and paste delays). The key is never logged.                                                                           |
| Diagnostics      | `OSCARS_WHISPER_DEBUG=1` logs bar input and clipboard decisions (lengths only, never text).                                                                                                                                                                       |

## 4. File map

| Path                                                                  | Responsibility                                                                               |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `src/main/index.js`                                                   | Startup and wiring: windows, key hook, state machine, level meter, bar IPC, right-click menu |
| `src/main/constants.js`                                               | All timing and audio constants                                                               |
| `src/main/config.js`                                                  | Settings loading and redaction                                                               |
| `src/main/debug.js`                                                   | Opt-in debug logging                                                                         |
| `src/main/keyboard/keys.js`, `shortcutMatcher.js`                     | Key names, default bindings, held-key matching                                               |
| `src/main/dictation/controller.js`                                    | Dictation state machine                                                                      |
| `src/main/flowbar/flowBarWindow.js`, `inputShape.js`                  | Bar window and click-through shape                                                           |
| `src/main/audio/recorderBridge.js`, `wav.js`, `levelMeter.js`         | Recorder IPC, WAV encoding, waveform levels                                                  |
| `src/main/pipeline/pipeline.js`, `model.js`, `cleanup.js`, `paste.js` | Transcribe → clean up → paste; `model.js` is where API calls go                              |
| `src/preload/*.mjs`                                                   | The narrow bridges each window can use                                                       |
| `src/renderer/flowbar/`                                               | Bar page (HTML/CSS/JS)                                                                       |
| `src/renderer/recorder/`                                              | Hidden microphone page and audio worklet                                                     |
| `src/shared/channels.js`                                              | IPC channel names                                                                            |
| `test/`                                                               | Unit tests (`support/controllerHarness.js` has the fake clock and recorder)                  |
| `scripts/e2e-linux/`                                                  | End-to-end test (Linux only)                                                                 |

## 5. Tests

### 5.1 Unit tests: `npm test` (100 passing)

These use Node's built-in test runner with a fake clock, so there are no real
waits.

| File                           | Tests | Covers                                                                                                                                                                                                                                                   |
| ------------------------------ | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `shortcutMatcher.test.js`      | 27    | Left/right modifier equivalence, either press order, auto-repeat ignored, exact matching, hands-free and Esc bindings, macOS defaults, stale-key sweep at the 60 s boundary, `reset()`, both-Ctrl-keys release                                           |
| `controller.test.js`           | 20    | Hold-to-talk start/stop, accidental-tap dismissal, double press locks, triple press dismisses, re-press stops, hands-free toggle and double-press dismiss, bar click stop, 500 ms boundaries                                                             |
| `controllerResilience.test.js` | 11    | Busy guard while processing, recorder start failures and stale results, `stop()` after failure, no-audio dismissal at 5 s, 19-minute warning, 20-minute stop                                                                                             |
| `inputShape.test.js`           | 26    | Report validation (non-finite values, >512 rects, bad viewport), pixel snapping/clipping/sorting/deduping, 128-rect cap, sender and viewport checks, hidden shape after disable, no redundant `setShape`, mouse input only while a pill shape is applied |
| `wav.test.js`                  | 12    | Every WAV header field, payload unchanged, duration math                                                                                                                                                                                                 |
| `levelMeter.test.js`           | 4     | dB conversion, 20 dB scaling and clamping, floor only moves down, averaging per update                                                                                                                                                                   |

The test agent also mutated the source about 70 ways to check that the tests
catch real changes. It added tests for every mutation that survived, except
three timer guards that can't be observed by any test.

### 5.2 End-to-end test: `PYTHON=python3.12 bash scripts/e2e-linux/run.sh`

The script runs the real app on a virtual X display (Xvfb) with Chromium's fake
microphone. It types with `xdotool` and pastes into a separate Tk text window.
The clipboard starts as `ORIGINAL CLIPBOARD`. It needs Xvfb, xdotool, xclip and
a Python with tkinter (set `PYTHON` if the default lacks it). It checks its
prerequisites and judges PASS/FAIL itself.

| Scenario                                      | Expected                         | Result |
| --------------------------------------------- | -------------------------------- | ------ |
| Hold Ctrl+Super 2 s                           | One paste, clipboard restored    | PASS   |
| Click bar (hands-free), then press the hotkey | Second paste, clipboard restored | PASS   |
| 100 ms tap                                    | Discarded, nothing pasted        | PASS   |

### 5.3 Static checks

REA's formatter and linter (`oxfmt`, `oxlint`) run on every commit through the
repo's hooks: 0 errors. There are two "function too long" warnings, both on
test `describe` blocks. The pre-push typecheck and lint passed.

## 6. Bugs found by testing (all fixed)

| Bug                                                    | Found by                      | Cause                                                                                                                                  | Fix                                                                      |
| ------------------------------------------------------ | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Bar could not be clicked                               | End-to-end run                | The shaped window was also told to ignore the mouse permanently. Wispr pairs that with a separate hit test, which had not been copied. | The window takes input only while a pill shape is applied                |
| Clipboard never restored                               | End-to-end run plus debug log | Electron 44's clipboard functions return Promises. The code treated them as plain values.                                              | Await them                                                               |
| Releasing one of two held Ctrl keys ended push-to-talk | Test agent                    | Left and right Ctrl were merged before tracking held keys                                                                              | Track physical keys; a key is released only when all its variants are up |
| Consecutive dictations ran together                    | End-to-end run                | No space between pastes                                                                                                                | Trailing space, as Wispr adds when nothing follows the cursor            |

Also fixed: `npm test` used a form Node 24 rejects (`node --test test/`). An
early run of the end-to-end script reported nothing pasted because its target
window silently failed to start. The script now fails loudly instead.

## 7. Not tested here, and why

The sandbox is a Linux container with no physical screen, microphone, speakers
or keyboard, and no Windows or macOS. Everything below needs a real device.
Highest risk first:

| #   | What to check on your PC                                                                                                                                  | Why it couldn't be tested                                            | Risk if it's wrong                                          |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | `npm install` and `npm start` work on Windows (the folder name has an apostrophe and a space)                                                             | No Windows                                                           | App won't start                                             |
| 2   | Ctrl+Win is detected and does not open the Start menu or trigger Windows shortcuts                                                                        | Synthetic X11 keys only; libuiohook on Windows uses a different hook | Hotkey doesn't work, or Windows reacts to it                |
| 3   | A real microphone records: built-in, USB, Bluetooth headset                                                                                               | Only Chromium's fake mic                                             | Silence; or the 5 s no-audio dismiss triggers               |
| 4   | The microphone permission prompt and the Windows privacy setting                                                                                          | No Windows privacy layer                                             | Nothing records                                             |
| 5   | Paste into real apps: Notepad, Word, browser text boxes, Slack, VS Code                                                                                   | Only a Tk text box                                                   | Paste lands nowhere or in the wrong place                   |
| 6   | Apps running **as administrator**: Windows blocks a normal app from sending keys to them                                                                  | No Windows security boundaries                                       | No paste into admin windows (text stays on the clipboard)   |
| 7   | Terminals (Ctrl+V may not paste), remote desktop, games                                                                                                   | Not available                                                        | No paste                                                    |
| 8   | Clicking the bar doesn't take focus away from the app you're typing in                                                                                    | X11 without a window manager behaves differently from Windows        | Paste goes to the bar instead of your app                   |
| 9   | Bar position and click area on high-DPI displays (125%/150% scaling), multiple monitors, taskbar on the side or auto-hidden                               | One virtual 1280×800 screen at 100%                                  | Bar misplaced, or click area offset from the pill           |
| 10  | Transparent window looks right (no black box)                                                                                                             | No compositor in the sandbox                                         | Cosmetic                                                    |
| 11  | Clipboard: Windows clipboard history (Win+V) and clipboard managers will record each transcript; images/files on the clipboard are replaced, not restored | Text-only test                                                       | Privacy and convenience                                     |
| 12  | Slow apps that read the clipboard late (600 ms restore window)                                                                                            | Not available                                                        | The old clipboard gets pasted                               |
| 13  | Holding keys while the screen locks or the PC sleeps (stale-key sweep after 60 s)                                                                         | Not available                                                        | A stuck "held" key until the sweep runs                     |
| 14  | Antivirus or SmartScreen warnings about a global keyboard hook                                                                                            | Not available                                                        | App blocked or quarantined                                  |
| 15  | A full 20-minute recording (memory, warning, auto-stop on real time)                                                                                      | Unit-tested with a fake clock only                                   | Unexpected stop or memory use; about 38 MB of audio is held |
| 16  | Hover/expand animation feel and waveform movement with real speech                                                                                        | Not visible in the sandbox                                           | Cosmetic                                                    |
| 17  | **macOS:** Accessibility and Input Monitoring prompts, the Ctrl+Option hotkeys, the mouse-forwarding click path, panel window behavior                    | No macOS                                                             | Hotkey, bar or paste doesn't work on Mac                    |
| 18  | Real AI providers: request format, latency, errors, timeouts, large uploads                                                                               | Not implemented yet (placeholders)                                   | Unknown until written                                       |

To diagnose any of these, run with `$env:OSCARS_WHISPER_DEBUG = "1"; npm start`
and keep the console output.

## 8. Known limitations by design

- No cursor context. Wispr's helper reads the text around the cursor to fix
  casing, spacing and punctuation. This app always appends one trailing space
  and can't match the surrounding capitalization.
- Only clipboard text is restored.
- Transcription is one upload at the end. Wispr streams while you speak.
- No Fn-key hotkeys on macOS.
- No Wispr extras: dictionary and snippets, command mode, "press enter",
  history, notes, meeting recorder, settings window.

## 9. Suggested next steps

1. Run section 7, items 1–9, on your Windows PC.
2. Pick a speech-to-text provider and a cleanup model. Then fill in the two
   `TODO(api-key)` blocks in `src/main/pipeline/model.js`.
3. Optionally: a settings window for hotkeys and the key, a packaged installer
   (e.g. electron-builder), and streaming transcription.

## 10. Provenance

- This is an independent rewrite based on behavior recovered with REA from
  Wispr Flow 1.6.1209, which you supplied from your own installation.
- No Wispr source code, assets, API keys or endpoints are included. A static
  model-host key found inside Wispr's bundle was deliberately left out.
- The decompiled Wispr files stayed in the temporary sandbox and were not
  committed.
- Icons are original simple SVGs. Dependencies are Electron and
  [uiohook-napi](https://github.com/SnosMe/uiohook-napi).

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
