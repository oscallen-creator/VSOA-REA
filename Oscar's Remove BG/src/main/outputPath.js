// remove.bg's naming rule: <output folder>/<relative input path> with the last
// extension replaced by the output format. No suffix, never an overwrite.

import path from "node:path";

/** What each background mode and the Photoshop option produce. */
export const outputFormat = ({ bgMode, usePsd }) => {
  if (bgMode === "color") return "jpg";
  return usePsd ? "psd" : "png";
};

/**
 * @param {string} outputDir absolute folder
 * @param {string} relativePath "/"-separated, e.g. "Trip/beach.jpeg"
 * @param {"png"|"jpg"|"psd"} format
 */
export const resultPath = (outputDir, relativePath, format) => {
  const segments = relativePath.split("/");
  if (
    segments.some(
      (segment) => segment === "" || segment === "." || segment === "..",
    )
  ) {
    throw new Error(`Unsafe relative path ${JSON.stringify(relativePath)}`);
  }
  const last = segments.pop().replace(/\.[^.]+$/, "");
  return path.join(outputDir, ...segments, `${last}.${format}`);
};
