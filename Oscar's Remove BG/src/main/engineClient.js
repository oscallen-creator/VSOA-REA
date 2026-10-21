// Owns the engine utility process: starts it on first use, matches results
// to requests, and fails every pending job (as fatal) if the process dies, so
// the next Start gets a fresh process.

import { utilityProcess } from "electron";

export const createEngineClient = ({ hostPath, modelDir, onModelProgress }) => {
  let child = null;
  let nextId = 1;
  const pending = new Map();

  const failAll = (message) => {
    for (const { reject } of pending.values()) {
      reject(Object.assign(new Error(message), { fatal: true }));
    }
    pending.clear();
  };

  const spawn = () => {
    const created = utilityProcess.fork(hostPath, [modelDir], {
      serviceName: "Oscar's Remove BG engine",
      stdio: "inherit",
    });
    created.on("message", (message) => {
      if (message?.type === "model-progress") {
        onModelProgress?.(message);
        return;
      }
      if (message?.type !== "result") return;
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.ok) request.resolve(message);
      else {
        request.reject(
          Object.assign(new Error(message.error.message), message.error),
        );
      }
    });
    created.on("exit", (code) => {
      if (child === created) child = null;
      failAll(`The image engine stopped unexpectedly (exit code ${code}).`);
    });
    return created;
  };

  const run = (job) =>
    new Promise((resolve, reject) => {
      child ??= spawn();
      const id = nextId++;
      pending.set(id, { resolve, reject });
      child.postMessage({ type: "process", id, ...job });
    });

  const dispose = () => {
    const running = child;
    child = null;
    running?.kill();
  };

  return { run, dispose };
};
