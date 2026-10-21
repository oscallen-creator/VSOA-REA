import { contextBridge, ipcRenderer } from "electron";
import { Channel } from "../shared/channels.js";

contextBridge.exposeInMainWorld("recorderBridge", {
  onCommand: (listener) =>
    ipcRenderer.on(Channel.RecorderCommand, (_event, command) =>
      listener(command),
    ),
  started: () => ipcRenderer.send(Channel.RecorderStarted),
  chunk: (pcm) => ipcRenderer.send(Channel.RecorderChunk, pcm),
  level: (rms) => ipcRenderer.send(Channel.RecorderLevel, rms),
  done: () => ipcRenderer.send(Channel.RecorderDone),
  error: (message) => ipcRenderer.send(Channel.RecorderError, message),
});
