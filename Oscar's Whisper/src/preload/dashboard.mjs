import { contextBridge, ipcRenderer } from "electron";
import { Channel } from "../shared/channels.js";

contextBridge.exposeInMainWorld("dashboard", {
  getState: () => ipcRenderer.invoke(Channel.DashboardGetState),
  onHistory: (listener) =>
    ipcRenderer.on(Channel.DashboardHistory, (_event, entries) =>
      listener(entries),
    ),
  clearHistory: () => ipcRenderer.send(Channel.DashboardClearHistory),
  recordShortcut: () => ipcRenderer.invoke(Channel.DashboardRecordShortcut),
  onHotkeysReady: (listener) =>
    ipcRenderer.on(Channel.DashboardHotkeysReady, (_event, ready) =>
      listener(ready),
    ),
  openAccessibility: () => ipcRenderer.send(Channel.DashboardOpenAccessibility),
});
