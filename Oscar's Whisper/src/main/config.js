// Settings come from `<userData>/config.json`. Only the keys below are read; anything else in
// the file (for example an API key from an older version) is ignored and never logged. A value
// of the wrong type is ignored too, with a warning, and the default is used.

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const DEFAULTS = Object.freeze({
  /** Optional overrides, e.g. {"ctrl+win": "ptt", "ctrl+space+win": "popo"}. */
  shortcuts: {},
  /** Wait between writing the clipboard and sending the paste keystroke. */
  pasteDelayMs: 50,
  /** Wait after the paste keystroke before restoring the previous clipboard. */
  restoreClipboardDelayMs: 600,
});

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

const isValid = {
  shortcuts: (value) =>
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.values(value).every((action) => typeof action === "string"),
  pasteDelayMs: (value) => Number.isFinite(value) && value >= 0,
  restoreClipboardDelayMs: (value) => Number.isFinite(value) && value >= 0,
};

export const loadConfig = async ({ userDataDir, warn = console.warn }) => {
  const file = path.join(userDataDir, "config.json");
  const values = await readConfigFile(file);
  const config = { ...DEFAULTS, file };
  for (const key of Object.keys(DEFAULTS)) {
    if (!Object.hasOwn(values, key)) continue;
    if (isValid[key](values[key])) config[key] = values[key];
    else warn(`[oscars-whisper] ignoring invalid "${key}" in ${file}`);
  }
  return config;
};

/** Writes new shortcuts into the config file, keeping everything else in it as it was. */
export const saveShortcuts = async (file, shortcuts) => {
  const values = await readConfigFile(file);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify({ ...values, shortcuts }, null, 2)}\n`);
};
