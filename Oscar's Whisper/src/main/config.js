// Settings come from environment variables first, then `<userData>/config.json`.
// The API key is never logged; use describeConfig() for diagnostics.

import { readFile } from "node:fs/promises";
import path from "node:path";

const DEFAULTS = Object.freeze({
  apiKey: "",
  transcriptionModel: "",
  cleanupModel: "",
  /** Optional overrides, e.g. {"ctrl+win": "ptt", "ctrl+space+win": "popo"}. */
  shortcuts: {},
  /** Wait between writing the clipboard and sending the paste keystroke. */
  pasteDelayMs: 50,
  /** Wait after the paste keystroke before restoring the previous clipboard. */
  restoreClipboardDelayMs: 600,
});

const fromEnvironment = (env) => {
  const values = {
    apiKey: env.OSCARS_WHISPER_API_KEY,
    transcriptionModel: env.OSCARS_WHISPER_TRANSCRIPTION_MODEL,
    cleanupModel: env.OSCARS_WHISPER_CLEANUP_MODEL,
  };
  return Object.fromEntries(
    Object.entries(values).filter(([, value]) => value),
  );
};

const readConfigFile = async (file) => {
  try {
    const parsed = JSON.parse(await readFile(file, "utf8"));
    return typeof parsed === "object" &&
      parsed !== null &&
      !Array.isArray(parsed)
      ? parsed
      : {};
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw new Error(`Could not read ${file}: ${error.message}`, {
      cause: error,
    });
  }
};

export const loadConfig = async ({ userDataDir, env = process.env }) => {
  const file = path.join(userDataDir, "config.json");
  return {
    ...DEFAULTS,
    ...(await readConfigFile(file)),
    ...fromEnvironment(env),
    file,
  };
};

export const describeConfig = (config) => ({
  ...config,
  apiKey: config.apiKey ? "(set)" : "(not set)",
});
