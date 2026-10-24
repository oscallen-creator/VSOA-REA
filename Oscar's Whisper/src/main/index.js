// Oscar's Whisper main process: always-on bar, global hotkey, recorder window and the
// transcribe -> clean up -> paste pipeline.

import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  session,
  systemPreferences,
} from "electron";
import path from "node:path";
import { fileURLToPath } from "node:url";
import uiohookModule from "uiohook-napi";
import { Channel } from "../shared/channels.js";
import { LEVEL_UPDATE_MS, LevelMeter } from "./audio/levelMeter.js";
import { RecorderBridge } from "./audio/recorderBridge.js";
import { loadConfig } from "./config.js";
import { debug } from "./debug.js";
import { STALE_KEY_SWEEP_MS } from "./constants.js";
import { DictationController, Source } from "./dictation/controller.js";
import { createFlowBarWindow } from "./flowbar/flowBarWindow.js";
import { Action, defaultBindings } from "./keyboard/keys.js";
import { ShortcutMatcher } from "./keyboard/shortcutMatcher.js";
import { pasteText } from "./pipeline/paste.js";
import { createPipeline } from "./pipeline/pipeline.js";
import { SPEECH_MODEL } from "./transcription/speechModel.js";
import { Transcriber } from "./transcription/transcriber.js";

const { uIOhook } = uiohookModule;
const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);
const MODIFIERS = new Set(["ctrl", "win", "alt", "shift"]);
const ACCESSIBILITY_POLL_MS = 2_000;
/** The installed app carries the model in its resources folder; development uses models/. */
const speechModelDir = () =>
  path.join(
    app.isPackaged ? process.resourcesPath : appRoot,
    "models",
    SPEECH_MODEL.id,
  );

let bar = null;
let recorderWindow = null;

const sendToBar = (channel, value) => {
  if (bar && !bar.window.isDestroyed())
    bar.window.webContents.send(channel, value);
};

const createRecorderWindow = () => {
  const window = new BrowserWindow({
    show: false,
    webPreferences: {
      preload: path.join(appRoot, "src", "preload", "recorder.mjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false,
    },
  });
  window.loadFile(
    path.join(appRoot, "src", "renderer", "recorder", "index.html"),
  );
  return window;
};

const allowMicrophoneOnly = () => {
  session.defaultSession.setPermissionRequestHandler(
    (_contents, permission, callback) => callback(permission === "media"),
  );
};

const createKeyboard = (config, getDictation) =>
  new ShortcutMatcher({
    bindings: { ...defaultBindings(), ...config.shortcuts },
    onActionDown: (action) => {
      const dictation = getDictation();
      if (action === Action.PushToTalk) dictation.pushToTalkDown();
      else if (action === Action.HandsFree)
        dictation.toggleHandsFree(Source.Keyboard);
      else if (action === Action.Dismiss) dictation.dismiss("escape");
    },
    onActionUp: (action) => {
      if (action === Action.PushToTalk) getDictation().pushToTalkUp();
    },
  });

const startKeyboardHook = (matcher) => {
  uIOhook.on("keydown", (event) => matcher.press(event.keycode));
  uIOhook.on("keyup", (event) => matcher.release(event.keycode));
  try {
    uIOhook.start();
  } catch (error) {
    // Clicking the bar still dictates without the hook, so report instead of quitting.
    console.error("[oscars-whisper] keyboard hook failed to start:", error);
    sendToBar(Channel.BarNotice, `error:${error.message}`);
    return;
  }
  const sweep = setInterval(() => matcher.sweepStaleKeys(), STALE_KEY_SWEEP_MS);
  app.on("will-quit", () => {
    clearInterval(sweep);
    uIOhook.stop();
  });
};

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
  console.log("[oscars-whisper] Accessibility permission granted");
};

/** Starts loading the speech model in the background; failures are reported, then retried on use. */
const createTranscriber = () => {
  const transcriber = new Transcriber({ modelDir: speechModelDir() });
  const started = Date.now();
  transcriber.load().then(
    () =>
      console.log(
        `[oscars-whisper] speech model ready in ${Date.now() - started} ms`,
      ),
    (error) => {
      console.error("[oscars-whisper] speech model failed to load:", error);
      sendToBar(Channel.BarNotice, `error:${error.message}`);
    },
  );
  return transcriber;
};

/** Bar level meter: dB-scaled chunk levels, averaged and sent every 150 ms. */
const createLevelFeed = () => {
  const meter = new LevelMeter();
  let micActive = false;
  setInterval(() => {
    const level = meter.drain();
    if (level !== null) sendToBar(Channel.BarLevel, level);
  }, LEVEL_UPDATE_MS);
  return {
    push(rms) {
      if (!micActive) {
        micActive = true;
        sendToBar(Channel.BarMicActive, true);
      }
      meter.push(rms);
    },
    reset() {
      meter.reset();
      if (micActive) sendToBar(Channel.BarMicActive, false);
      micActive = false;
    },
  };
};

/**
 * Login items point at the running executable, so they are only offered in the installed app
 * (in development that would be the bare Electron binary). Electron has no login items on Linux.
 */
const startAtLoginItems = () => {
  if (!app.isPackaged || process.platform === "linux") return [];
  return [
    {
      label: "Start at login",
      type: "checkbox",
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { type: "separator" },
  ];
};

const fromBar = (event) => event.sender === bar?.window.webContents;

const handleBarInput = (dictation) => {
  ipcMain.on(Channel.BarStartClicked, (event) => {
    debug(`bar: start clicked (active=${dictation.isActive})`);
    if (fromBar(event) && !dictation.isActive)
      dictation.toggleHandsFree(Source.Bar);
  });
  ipcMain.on(Channel.BarStopClicked, (event) => {
    if (fromBar(event)) void dictation.stop("stop_button");
  });
  ipcMain.on(Channel.BarCancelClicked, (event) => {
    if (fromBar(event)) dictation.dismiss("cancel_button");
  });
  ipcMain.on(Channel.BarShapeReport, (event, report) => {
    const applied = bar?.inputShape?.applyReport(event.sender, report);
    debug(
      "bar: shape report",
      JSON.stringify(report?.rects),
      `applied=${applied}`,
    );
  });
  ipcMain.on(Channel.BarHover, (event, inside) => {
    if (!fromBar(event) || bar.inputShape) return;
    bar.window.setIgnoreMouseEvents(!inside, { forward: true });
  });
  ipcMain.on(Channel.BarContextMenu, (event) => {
    if (!fromBar(event)) return;
    Menu.buildFromTemplate([
      { label: "Oscar's Whisper", enabled: false },
      { type: "separator" },
      ...startAtLoginItems(),
      { label: "Quit", click: () => app.quit() },
    ]).popup({ window: bar.window });
  });
};

const main = async () => {
  await app.whenReady();
  if (process.platform === "darwin") {
    app.dock?.hide();
    await systemPreferences.askForMediaAccess("microphone");
  }
  allowMicrophoneOnly();
  const config = await loadConfig({ userDataDir: app.getPath("userData") });
  console.log("[oscars-whisper] config", config);

  recorderWindow = createRecorderWindow();
  bar = createFlowBarWindow({ appRoot });
  const levels = createLevelFeed();
  const recorder = new RecorderBridge({
    ipcMain,
    getWindow: () => recorderWindow,
    onLevel: (rms) => levels.push(rms),
  });
  let dictation = null;
  const keyboard = createKeyboard(config, () => dictation);
  const pipeline = createPipeline({
    config,
    transcriber: createTranscriber(),
    paste: pasteText,
    isModifierHeld: () => keyboard.heldKeys.some((key) => MODIFIERS.has(key)),
  });
  dictation = new DictationController({
    recorder,
    process: async (pcm) => {
      const result = await pipeline.run(pcm);
      if (!result.pasted)
        console.log("[oscars-whisper] nothing pasted:", result.reason);
    },
    onChange: (state) => {
      if (state.status !== "listening") levels.reset();
      sendToBar(Channel.BarState, state);
    },
    onNotice: (notice) => {
      console.log("[oscars-whisper]", notice);
      sendToBar(Channel.BarNotice, notice);
    },
  });
  handleBarInput(dictation);
  await whenAccessibilityTrusted();
  startKeyboardHook(keyboard);
};

app.on("window-all-closed", () => {});
// A second copy (e.g. launched again from the Start menu) would add a second key hook and
// microphone, so every dictation would be pasted twice.
if (app.requestSingleInstanceLock()) {
  main().catch((error) => {
    console.error("[oscars-whisper] failed to start", error);
    app.exit(1);
  });
} else {
  console.log("[oscars-whisper] already running; this copy exits");
  app.quit();
}
