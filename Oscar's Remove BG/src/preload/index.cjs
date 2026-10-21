// The only bridge the window gets. Sandboxed preloads must be CommonJS, so
// this file cannot use import.
// oxlint-disable-next-line typescript/no-var-requires
const { contextBridge, ipcRenderer, webUtils } = require("electron");

const subscribe = (channel) => (callback) => {
  const listener = (_event, value) => callback(value);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};

contextBridge.exposeInMainWorld("removeBg", {
  getState: () => ipcRenderer.invoke("app:state"),
  updateSettings: (patch) => ipcRenderer.invoke("settings:update", patch),
  /** Paths of dropped File objects; folders included. */
  addFiles: (files) =>
    ipcRenderer.invoke(
      "inputs:add",
      Array.from(files, (file) => webUtils.getPathForFile(file)).filter(
        Boolean,
      ),
    ),
  pickFiles: () => ipcRenderer.invoke("inputs:pick"),
  pickOutputFolder: () => ipcRenderer.invoke("output:pick"),
  start: () => ipcRenderer.invoke("queue:start"),
  cancel: () => ipcRenderer.invoke("queue:cancel"),
  clear: () => ipcRenderer.invoke("queue:clear"),
  remove: (id) => ipcRenderer.invoke("queue:remove", id),
  openResult: (id) => ipcRenderer.invoke("open:result", id),
  showInFolder: (id) => ipcRenderer.invoke("open:in-folder", id),
  openOutputFolder: () => ipcRenderer.invoke("open:output"),
  onQueue: subscribe("queue"),
  onModel: subscribe("model"),
  onAlert: subscribe("alert"),
});
