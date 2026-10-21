import { contextBridge, ipcRenderer } from "electron";
import { Channel } from "../shared/channels.js";

const subscribe = (channel, listener) =>
  ipcRenderer.on(channel, (_event, value) => listener(value));

contextBridge.exposeInMainWorld("flowBar", {
  onState: (listener) => subscribe(Channel.BarState, listener),
  onLevel: (listener) => subscribe(Channel.BarLevel, listener),
  onNotice: (listener) => subscribe(Channel.BarNotice, listener),
  click: () => ipcRenderer.send(Channel.BarClick),
  hover: (inside) => ipcRenderer.send(Channel.BarHover, inside),
  reportShape: (report) => ipcRenderer.send(Channel.BarShapeReport, report),
  contextMenu: () => ipcRenderer.send(Channel.BarContextMenu),
});
