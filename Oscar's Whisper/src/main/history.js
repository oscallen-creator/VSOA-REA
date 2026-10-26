// The most recent pasted dictations, newest first, kept in <userData>/history.json so the
// dashboard can show them after a restart. They never leave this computer, and the
// dashboard's Clear button deletes them. Like the logs, warnings never include their text.

import { readFile, writeFile } from "node:fs/promises";

export const HISTORY_LIMIT = 50;

const isEntry = (entry) =>
  typeof entry?.text === "string" && Number.isFinite(entry?.at);

export const loadHistory = async (file, { warn = console.warn } = {}) => {
  let entries = [];
  try {
    const parsed = JSON.parse(await readFile(file, "utf8"));
    if (Array.isArray(parsed))
      entries = parsed.filter(isEntry).slice(0, HISTORY_LIMIT);
  } catch (error) {
    if (error?.code !== "ENOENT")
      warn(`[oscars-whisper] ignoring unreadable ${file}`);
  }
  // Writes run one at a time, so a slow write can't land after a newer one.
  let saving = Promise.resolve();
  const save = () =>
    (saving = saving
      .then(() => writeFile(file, JSON.stringify(entries)))
      .catch(() => warn(`[oscars-whisper] could not save ${file}`)));
  return {
    get entries() {
      return entries;
    },
    add(text, at = Date.now()) {
      entries = [{ text, at }, ...entries].slice(0, HISTORY_LIMIT);
      return save();
    },
    clear() {
      entries = [];
      return save();
    },
  };
};
