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
import { RecorderBridge } from "./audio/recorderBridge.js";
import { loadConfig, describeConfig } from "./config.js";
import { STALE_KEY_SWEEP_MS } from "./constants.js";
import { DictationController, Source } from "./dictation/controller.js";
import { createFlowBarWindow } from "./flowbar/flowBarWindow.js";
import { Action, defaultBindings } from "./keyboard/keys.js";
import { ShortcutMatcher } from "./keyboard/shortcutMatcher.js";
import { createPipeline } from "./pipeline/pipeline.js";

const { uIOhook } = uiohookModule;
const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
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

const startKeyboard = (config, dictation) => {
  const matcher = new ShortcutMatcher({
    bindings: { ...defaultBindings(), ...config.shortcuts },
    onActionDown: (action) => {
      if (action === Action.PushToTalk) dictation.pushToTalkDown();
      else if (action === Action.HandsFree)
        dictation.toggleHandsFree(Source.Keyboard);
      else if (action === Action.Dismiss) dictation.dismiss("escape");
    },
    onActionUp: (action) => {
      if (action === Action.PushToTalk) dictation.pushToTalkUp();
    },
  });
  uIOhook.on("keydown", (event) => matcher.press(event.keycode));
  uIOhook.on("keyup", (event) => matcher.release(event.keycode));
  uIOhook.start();
  const sweep = setInterval(() => matcher.sweepStaleKeys(), STALE_KEY_SWEEP_MS);
  app.on("will-quit", () => {
    clearInterval(sweep);
    uIOhook.stop();
  });
};

const handleBarInput = (dictation) => {
  ipcMain.on(Channel.BarClick, (event) => {
    if (event.sender === bar?.window.webContents)
      dictation.toggleHandsFree(Source.Bar);
  });
  ipcMain.on(Channel.BarShapeReport, (event, report) =>
    bar?.inputShape?.applyReport(event.sender, report),
  );
  ipcMain.on(Channel.BarHover, (event, inside) => {
    if (event.sender !== bar?.window.webContents || bar.inputShape) return;
    bar.window.setIgnoreMouseEvents(!inside, { forward: true });
  });
  ipcMain.on(Channel.BarContextMenu, (event) => {
    if (event.sender !== bar?.window.webContents) return;
    Menu.buildFromTemplate([
      { label: "Oscar's Whisper", enabled: false },
      { type: "separator" },
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
  console.log("[oscars-whisper] config", describeConfig(config));

  recorderWindow = createRecorderWindow();
  bar = createFlowBarWindow({ appRoot });
  const recorder = new RecorderBridge({
    ipcMain,
    getWindow: () => recorderWindow,
    onLevel: (rms) => sendToBar(Channel.BarLevel, rms),
  });
  const pipeline = createPipeline({ config });
  const dictation = new DictationController({
    recorder,
    process: (pcm) => pipeline.run(pcm),
    onChange: (state) => sendToBar(Channel.BarState, state),
    onNotice: (notice) => {
      console.log("[oscars-whisper]", notice);
      sendToBar(Channel.BarNotice, notice);
    },
  });
  handleBarInput(dictation);
  startKeyboard(config, dictation);
};

app.on("window-all-closed", () => {});
main().catch((error) => {
  console.error("[oscars-whisper] failed to start", error);
  app.exit(1);
});
