// Main-process side of the hidden recorder window: start/stop/cancel commands go out,
// PCM chunks and levels come back. stop() resolves with the whole recording as PCM bytes.

import { Channel } from "../../shared/channels.js";

const COMMAND_TIMEOUT_MS = 10_000;

export class RecorderBridge {
  #getWindow;
  #onLevel;
  #chunks = [];
  #pending = null;

  constructor({ ipcMain, getWindow, onLevel = () => {} }) {
    this.#getWindow = getWindow;
    this.#onLevel = onLevel;
    ipcMain.on(Channel.RecorderChunk, (event, pcm) => {
      if (this.#fromRecorder(event)) this.#chunks.push(Buffer.from(pcm));
    });
    ipcMain.on(Channel.RecorderLevel, (event, rms) => {
      if (this.#fromRecorder(event)) this.#onLevel(rms);
    });
    ipcMain.on(Channel.RecorderStarted, (event) =>
      this.#settle(event, "start"),
    );
    ipcMain.on(Channel.RecorderDone, (event) => this.#settle(event, "stop"));
    ipcMain.on(Channel.RecorderError, (event, message) => {
      if (!this.#fromRecorder(event)) return;
      const pending = this.#pending;
      this.#pending = null;
      pending?.reject(new Error(`Microphone: ${message}`));
    });
  }

  start() {
    this.#chunks = [];
    return this.#command("start");
  }

  async stop() {
    await this.#command("stop");
    const pcm = Buffer.concat(this.#chunks);
    this.#chunks = [];
    return pcm;
  }

  async cancel() {
    this.#chunks = [];
    this.#pending?.reject(new Error("cancelled"));
    this.#pending = null;
    this.#getWindow()?.webContents.send(Channel.RecorderCommand, "cancel");
  }

  #command(name) {
    const window = this.#getWindow();
    if (!window || window.isDestroyed()) {
      return Promise.reject(new Error("Recorder window is not available"));
    }
    this.#pending?.reject(new Error(`superseded by ${name}`));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.#pending?.name !== name) return;
        this.#pending = null;
        reject(new Error(`Recorder did not acknowledge "${name}"`));
      }, COMMAND_TIMEOUT_MS);
      const clear = (fn) => (value) => {
        clearTimeout(timer);
        fn(value);
      };
      this.#pending = { name, resolve: clear(resolve), reject: clear(reject) };
      window.webContents.send(Channel.RecorderCommand, name);
    });
  }

  #settle(event, name) {
    if (!this.#fromRecorder(event) || this.#pending?.name !== name) return;
    const pending = this.#pending;
    this.#pending = null;
    pending.resolve();
  }

  #fromRecorder(event) {
    return event.sender === this.#getWindow()?.webContents;
  }
}
