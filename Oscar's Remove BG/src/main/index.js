// Oscar's Remove BG main process: one window, the image list and its run,
// and an engine utility process that removes backgrounds locally.
//
// Unlike remove.bg desktop, the window gets no generic file-system bridge:
// it can only ask for the actions below, and paths it may open come from
// this process's own list and settings.

import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  Menu,
  session,
  shell,
} from "electron";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { defaultModelDir } from "../engine/modelStore.js";
import { createEngineClient } from "./engineClient.js";
import {
  collectInputs,
  describeRejections,
  IMAGE_EXTENSIONS,
} from "./inputs.js";
import { createQueue } from "./queue.js";
import { createSettingsStore, defaultSettings, PALETTE } from "./settings.js";

const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);
const pageFile = path.join(appRoot, "src", "renderer", "index.html");
const pageUrl = pathToFileURL(pageFile).href;

let window = null;
let modelStatus = { state: "idle", received: 0, total: 0 };

const send = (channel, value) => {
  if (window && !window.isDestroyed()) window.webContents.send(channel, value);
};

const settings = createSettingsStore({
  file: path.join(app.getPath("userData"), "settings.json"),
  defaults: defaultSettings({ picturesDir: app.getPath("pictures") }),
});

const engine = createEngineClient({
  hostPath: path.join(appRoot, "src", "main", "engineHost.js"),
  modelDir: process.env.OSCARS_REMOVE_BG_MODELS || defaultModelDir(),
  onModelProgress: ({ received, total }) => {
    modelStatus = {
      state: received >= total ? "ready" : "downloading",
      received,
      total,
    };
    send("model", modelStatus);
  },
});

const queue = createQueue({
  runJob: engine.run,
  getSettings: settings.get,
  onChange: (snapshot) => send("queue", snapshot),
  onAlert: (message) => send("alert", { message }),
});

const addPaths = async (paths) => {
  const { accepted, rejected } = await collectInputs(
    paths,
    queue.knownSources(),
    { outputFolder: settings.get().outputPath },
  );
  const added = queue.add(accepted);
  return {
    added: added.length,
    message: describeRejections(added.length, rejected),
  };
};

const rowOutput = (id) => queue.findRow(id)?.output?.path ?? null;

const openOutputFolder = async () => {
  const folder = settings.get().outputPath;
  await mkdir(folder, { recursive: true });
  return shell.openPath(folder);
};

// Every handler checks that the request comes from our own page.
const handle = (channel, handler) =>
  ipcMain.handle(channel, (event, ...args) => {
    if (event.senderFrame?.url !== pageUrl) {
      throw new Error(`Rejected ${channel} from ${event.senderFrame?.url}`);
    }
    return handler(...args);
  });

const registerIpc = () => {
  handle("app:state", () => ({
    queue: queue.snapshot(),
    settings: settings.get(),
    model: modelStatus,
    palette: PALETTE,
    platform: process.platform,
    version: app.getVersion(),
  }));
  handle("settings:update", (patch) => settings.update(patch));
  handle("inputs:add", (paths) =>
    addPaths(
      Array.isArray(paths) ? paths.filter((p) => typeof p === "string") : [],
    ),
  );
  handle("inputs:pick", async () => {
    const { canceled, filePaths } = await dialog.showOpenDialog(window, {
      properties: ["openFile", "multiSelections"],
      filters: [
        {
          name: "Images",
          extensions: IMAGE_EXTENSIONS.map((ext) => ext.slice(1)),
        },
      ],
    });
    return canceled ? { added: 0, message: null } : addPaths(filePaths);
  });
  handle("output:pick", async () => {
    const current = settings.get().outputPath;
    const { canceled, filePaths } = await dialog.showOpenDialog(window, {
      properties: ["openDirectory", "createDirectory"],
      defaultPath: current,
    });
    if (canceled || filePaths.length === 0) return settings.get();
    return settings.update({ outputPath: filePaths[0] });
  });
  handle("queue:start", () => queue.start());
  handle("queue:cancel", () => queue.cancel());
  handle("queue:clear", () => queue.clear());
  handle("queue:remove", (id) => queue.remove(id));
  handle("open:result", (id) => {
    const file = rowOutput(id);
    return file ? shell.openPath(file) : "No result yet";
  });
  handle("open:in-folder", (id) => {
    const file = rowOutput(id);
    if (file) shell.showItemInFolder(file);
  });
  handle("open:output", openOutputFolder);
};

const createWindow = () => {
  window = new BrowserWindow({
    width: 900,
    height: 680,
    minWidth: 720,
    minHeight: 520,
    title: "Oscar's Remove BG",
    show: false,
    backgroundColor: "#f4f5f7",
    webPreferences: {
      preload: path.join(appRoot, "src", "preload", "index.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  // Dropping a file outside the drop handler must not navigate away.
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.once("ready-to-show", () => window.show());
  window.loadFile(pageFile);
};

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", () => {
    if (window?.isMinimized()) window.restore();
    window?.focus();
  });
  app.whenReady().then(async () => {
    await settings.load();
    session.defaultSession.setPermissionRequestHandler((_c, _p, callback) =>
      callback(false),
    );
    if (process.platform !== "darwin") Menu.setApplicationMenu(null);
    registerIpc();
    createWindow();
  });
  app.on("window-all-closed", () => app.quit());
  app.on("will-quit", () => engine.dispose());
}
