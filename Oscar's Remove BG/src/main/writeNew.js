// Writes an output without ever replacing an existing file, the rule remove.bg
// desktop follows ("Skipped: File already exists"). "wx" also covers a file
// that appears between the caller's existence check and the write.

import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

/**
 * @returns {Promise<boolean>} false when the file already exists
 * Write failures are tagged `stage: "write"` so classifyError can tell an
 * unwritable output folder from an unreadable input.
 */
export const writeNewFile = async (file, buffer) => {
  try {
    await mkdir(path.dirname(file), { recursive: true });
  } catch (error) {
    throw Object.assign(error, { stage: "write" });
  }
  try {
    await writeFile(file, buffer, { flag: "wx" });
    return true;
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    // A half-written file from this failed write is ours to remove.
    await rm(file, { force: true }).catch(() => {});
    throw Object.assign(error, { stage: "write" });
  }
};
