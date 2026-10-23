# Oscar's Whisper on macOS: handoff for the next agent

You are picking this up on the owner's **Apple Silicon Mac** (M-series). Goal: a
working, installable macOS build of Oscar's Whisper (`.dmg` → `/Applications`)
with the same features as the Windows build. The previous agent worked in a Linux
cloud container. It could not run or sign anything for macOS, so everything below
marked _unverified_ needs checking on this Mac.

**Short version:** this is **not** a new app. Oscar's Whisper is Electron, and the
code already has macOS paths. Three things block a usable Mac build. All three are
small, and the fixes are below:

1. **Accessibility crash (B1).** On first launch the app quits because the
   keyboard hook throws without Accessibility permission.
2. **Signing (B2).** The build must be ad-hoc signed, or macOS won't open it.
3. **Hardware test (B3).** Permissions, hotkeys, paste and the bar have never been
   run on a Mac.

Read [README.md](README.md) (usage, speech-to-text) and [HANDOFF.md](HANDOFF.md)
(design, tests, history) for everything not Mac-specific.

## 1. Get the code and build tools

The repository is public, so no login is needed. All work is on branch
`claude/epic-pascal-ylwp6i`, which is not merged into `main` yet. This fetches
only this folder:

```bash
git clone --filter=blob:none --sparse --branch claude/epic-pascal-ylwp6i https://github.com/oscallen-creator/VSOA-REA.git
cd VSOA-REA
git sparse-checkout set "Oscar's Whisper"
cd "Oscar's Whisper"
```

- **Node.js 22 or newer** (24 recommended), for example from the macOS installer
  at <https://nodejs.org>. `git` may prompt to install the Xcode Command Line Tools
  the first time; accept.
- `npm install` pulls `sherpa-onnx-darwin-arm64` automatically. It is an optional
  dependency selected by OS and CPU, and the lockfile already pins it with its
  integrity hash.
- `npm start` and `npm run dist:mac` first run `npm run fetch-model`. That
  downloads the 482 MB speech model once and checks its SHA-256. It needs about
  1.2 GB of free disk while unpacking.
- Do **not** commit `models/`, `out/`, `node_modules/` or any `.dmg`. They are
  git-ignored.

## 2. What already supports macOS (in the code today)

| Area              | Where                                     | macOS behavior                                                                                                                                                     |
| ----------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Hotkeys           | `src/main/keyboard/keys.js`               | Hold **Ctrl+Option** to talk, **Ctrl+Option+Space** toggles hands-free, **Esc** cancels. Wispr's Fn-key default is not supported (it needs Wispr's native helper). |
| Bar window        | `src/main/flowbar/flowBarWindow.js`       | `type: "panel"`, visible on all workspaces and over full-screen apps, hidden in Mission Control. Click-through uses mouse forwarding (macOS has no `setShape`).    |
| No Dock icon      | `src/main/index.js`, `package.json` `mac` | `app.dock.hide()` plus `LSUIElement: true`. Quit is in the bar's right-click menu.                                                                                 |
| Microphone prompt | `src/main/index.js`                       | `systemPreferences.askForMediaAccess("microphone")` at startup; `NSMicrophoneUsageDescription` is set in `package.json`.                                           |
| Paste             | `src/main/pipeline/paste.js`              | Writes the clipboard, sends **Cmd+V** through uiohook, restores the old clipboard text.                                                                            |
| Speech engine     | `sherpa-onnx-darwin-arm64` 1.13.8         | See below.                                                                                                                                                         |
| Start at login    | `src/main/index.js` (`startAtLoginItems`) | Checkbox in the right-click menu, packaged app only.                                                                                                               |
| Packaging         | `package.json` → `build.mac`              | `dmg` target, productivity category. Other platforms' engine packages are excluded.                                                                                |

The speech engine was checked from Linux with `llvm-objdump`. Its
`sherpa-onnx.node`, `libsherpa-onnx-c-api.dylib` and `libonnxruntime.dylib` link
each other through `@rpath` with `LC_RPATH @loader_path`, so they load from their
own folder without `DYLD_LIBRARY_PATH`. Each carries an `LC_CODE_SIGNATURE`. The
package's SHA-512 matched the lockfile. The engine has **not** been run on macOS.

Also checked from Linux: electron-builder 26.15.3 assembled a `mac-arm64`
`OscarsWhisper.app`. It has the model in `Contents/Resources/models/`, the darwin
engine and uiohook in `app.asar.unpacked`, the notices file and `icon.icns`, and an
`Info.plist` with `LSUIElement` and `NSMicrophoneUsageDescription`. It skipped
signing with "supported only on macOS", so build on the Mac instead.

## 3. Required changes

### B1. Don't quit when Accessibility permission is missing (confirmed from source)

**Cause.** `uIOhook.start()` (at the end of `main()` in `src/main/index.js`)
calls libuiohook, which calls `AXIsProcessTrustedWithOptions` with the prompt
option (`libuiohook/src/darwin/input_helper.c`). Without permission it returns
`UIOHOOK_ERROR_AXAPI_DISABLED`, which the addon throws as "Failed to enable access
for assistive devices." (`uiohook-napi/src/lib/addon.c:228`). `main().catch` then
calls `app.exit(1)`. So on first launch the app shows the macOS prompt and
**quits immediately**. Accessibility is also needed for the Cmd+V paste keystroke
(posting synthetic events).

**Fix sketch** (in `src/main/index.js`, matching its style):

```js
const ACCESSIBILITY_POLL_MS = 2_000;

/**
 * macOS lets the key hook and the Cmd+V keystroke work only once the app is allowed under
 * System Settings → Privacy & Security → Accessibility. Ask once, then wait instead of quitting.
 */
const whenAccessibilityTrusted = async () => {
  if (process.platform !== "darwin") return;
  if (systemPreferences.isTrustedAccessibilityClient(true)) return;
  console.log("[oscars-whisper] waiting for Accessibility permission");
  await new Promise((resolve) => {
    const timer = setInterval(() => {
      if (!systemPreferences.isTrustedAccessibilityClient(false)) return;
      clearInterval(timer);
      resolve();
    }, ACCESSIBILITY_POLL_MS);
  });
};

// at the end of main():
await whenAccessibilityTrusted();
startKeyboardHook(keyboard);
```

Also wrap `uIOhook.start()` in `startKeyboardHook` in `try`/`catch`. On failure,
log it and send `error:…` to the bar (`sendToBar(Channel.BarNotice, …)`) instead
of letting it reach `app.exit(1)`. The bar's click-to-dictate still works without
the hook.

**Verify:**

1. Remove the app from Accessibility.
2. Launch it. The app must stay running and show the macOS prompt.
3. Grant the permission. Hotkeys must start working within about 2 s.
4. If macOS only applies the permission after a restart, document that in the
   README instead.

### B2. Ad-hoc signing (decided; follows electron-builder 26.15.3's own docs)

With no identity, electron-builder **skips signing** and has no automatic ad-hoc
fallback (see `node_modules/app-builder-lib/out/options/macOptions.d.ts`,
`identity`). An unsigned or re-packed arm64 bundle may be refused as "damaged".

Change `package.json`:

```json
"dist:mac": "electron-builder --mac --arm64",
```

```json
"mac": {
  "target": "dmg",
  "identity": "-",
  "hardenedRuntime": false,
  "category": "public.app-category.productivity",
  "extendInfo": { "LSUIElement": true, "NSMicrophoneUsageDescription": "Oscar's Whisper records your voice while you dictate." },
  "files": ["!node_modules/sherpa-onnx-{win,linux}-*/**"]
}
```

Why `hardenedRuntime: false`:

- Ad-hoc signing combined with the hardened runtime enforces library validation,
  which rejects Electron's frameworks and the sherpa-onnx dylibs (different or no
  Team ID). That would need the `com.apple.security.cs.disable-library-validation`
  entitlement.
- The microphone would additionally need `com.apple.security.device.audio-input`.
- Hardened runtime only matters for notarization, which needs a paid Developer ID.
  This build is for personal use.

**Verify:**

```bash
npm run dist:mac
ls out/   # expect OscarsWhisper-0.1.0-mac-arm64.dmg and out/mac-arm64/
codesign -dv --verbose=2 out/mac-arm64/OscarsWhisper.app 2>&1 | grep -E "Signature|Identifier"   # Signature=adhoc
codesign --verify --deep --strict --verbose=2 out/mac-arm64/OscarsWhisper.app
```

The bundle is `OscarsWhisper.app`, with executable `Contents/MacOS/OscarsWhisper`.
Its display name (`CFBundleName`) is "Oscar's Whisper". This was checked in the
bundle assembled on Linux; a build on the Mac should match.

### B3. Test on the Mac (nothing below has been run on macOS)

You can't click System Settings yourself. Ask the owner to grant permissions when
macOS asks.

1. `npm test`: 142 tests should pass. The two real-model tests need
   `npm run fetch-model` first. They use `readWave` in plain Node, which is fine
   (see note 4).
2. Dev run with `OSCARS_WHISPER_DEBUG=1 npm start`. When started from Terminal,
   macOS often attributes the Microphone and Accessibility requests to
   **Terminal** (or iTerm, or your editor), not Electron. Grant them there for
   development.
3. Build, open the `.dmg`, drag the app to **Applications**, and launch it. To see
   logs, start the binary from Terminal:
   `OSCARS_WHISPER_DEBUG=1 /Applications/OscarsWhisper.app/Contents/MacOS/OscarsWhisper`.
4. Checklist, in TextEdit, Notes, Safari or Chrome text boxes, Slack and VS Code:
   - Log shows `speech model ready in … ms`.
   - Bar is visible at the bottom centre of the screen under the cursor, including
     over a full-screen app and on a second display.
   - Hovering the bar expands it, and clicking starts hands-free.
   - Clicking the bar does not steal focus from the app you're typing in. This is
     the riskiest part: the panel type and mouse-forwarding path are untested.
   - Holding **Ctrl+Option**, speaking and releasing pastes the text with a
     trailing space, and the old clipboard text comes back.
   - **Ctrl+Option+Space** toggles hands-free; **Esc** cancels; a tap shorter
     than 0.5 s pastes nothing.
   - Right-click → **Start at login** survives a logout and login (Electron uses
     `SMAppService` there; untested with ad-hoc signing).
   - Right-click → **Quit** quits.
5. Measure on this Mac and add the results to README "Speed and memory": model
   load time (Linux: about 3 s), time from release to paste for a sentence of
   about 7 s (Linux: about 1 s), and memory in Activity Monitor (Linux: about
   0.9 GB). Apple Silicon should be at least as fast. The engine runs on CPU
   (`provider: "cpu"`); CoreML is not used.

## 4. Things to know

- **Permissions you'll see:**
  - Microphone, prompted at startup.
  - Accessibility, for the hotkeys and paste.
  - Possibly **Input Monitoring**, which macOS may ask for to listen to keys.
  - With an ad-hoc signature, macOS ties these grants to that exact build. After
    a rebuild you may need to remove the app from those lists and add it again.
- **First open of a downloaded copy:** a `.dmg` you built locally isn't
  quarantined, so it opens normally. A copy downloaded from the internet needs
  right-click → **Open**, or System Settings → Privacy & Security → **Open
  Anyway**. Alternatively, run `xattr -cr /Applications/OscarsWhisper.app`.
- **Size:** the model makes the `.dmg` roughly 550–600 MB. That's expected.
- **`readWave()` doesn't work in Electron:** sherpa-onnx's `readWave()` throws
  "External buffers are not allowed" in Electron. The app never calls it, because
  it passes the recorder's samples directly. Keep it that way.
- **Linux-only e2e test:** `scripts/e2e-linux/run.sh` needs Xvfb and xdotool, so
  it does not run on macOS. Test by hand as in B3.
- **Intel Macs:** build with `--x64`. That needs `sherpa-onnx-darwin-x64`, which
  npm installs on an Intel Mac. Not needed for this owner.

## 5. If Electron on macOS turns out to be a dead end (not recommended first)

A native Swift app would rebuild every piece rather than reuse them:

| Piece          | Native replacement                                           |
| -------------- | ------------------------------------------------------------ |
| Key hook       | `CGEventTap` with Accessibility permission                   |
| Bar            | Non-activating `NSPanel`                                     |
| Audio          | `AVAudioEngine` at 16 kHz mono                               |
| Speech-to-text | sherpa-onnx's C/Swift API with the same Parakeet model files |
| Paste          | `NSPasteboard` plus a posted Cmd+V `CGEvent`                 |

The behavior rules would need porting too: the timing rules in
`src/main/dictation/controller.js`, the chunking in
`src/main/transcription/chunking.js`, and the cleanup rules. Only consider this if
B1–B3 can't be made to work. Electron already covers each piece above.

## 6. When you're done

- Update README (macOS install and permissions, measured numbers) and HANDOFF
  (status table, section 7 checks you ran).
- Commit only inside `Oscar's Whisper/`, with Conventional Commit subjects (for
  example `fix(oscars-whisper): wait for Accessibility on macOS instead of
  quitting`), on branch `claude/epic-pascal-ylwp6i`, then push.
- Report what you verified on the Mac and what you could not.
