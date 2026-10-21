// Turns dropped or picked paths into queue entries with remove.bg's rules:
// folders are walked recursively, names starting with "." are skipped, the
// dropped folder's own name is kept in the relative output path, only JPEG,
// PNG, TIFF and WebP are accepted, and a source path is only added once.

import { readdir, stat } from "node:fs/promises";
import path from "node:path";

export const IMAGE_EXTENSIONS = Object.freeze([
  ".jpg",
  ".jpeg",
  ".png",
  ".tif",
  ".tiff",
  ".webp",
]);
/**
 * remove.bg's 22 MB cap was its upload limit. Processing locally allows more;
 * this only guards against files too large to decode comfortably.
 */
export const MAX_INPUT_BYTES = 200 * 1024 * 1024;

export const Rejection = Object.freeze({
  WrongType: "wrong_type",
  TooLarge: "too_large",
  AlreadyAdded: "already_added",
  Unreadable: "unreadable",
});

const isHidden = (name) => name.startsWith(".");
const isImageName = (name) =>
  IMAGE_EXTENSIONS.includes(path.extname(name).toLowerCase());

const classify = (file, size, known) => {
  if (!isImageName(file)) return Rejection.WrongType;
  if (size > MAX_INPUT_BYTES) return Rejection.TooLarge;
  if (known.has(file)) return Rejection.AlreadyAdded;
  return null;
};

async function* walk(directory, prefix) {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    yield { file: directory, relativePath: prefix, unreadable: true };
    return;
  }
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    if (isHidden(entry.name)) continue;
    const file = path.join(directory, entry.name);
    const relativePath = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) yield* walk(file, relativePath);
    else if (entry.isFile()) yield { file, relativePath };
  }
}

async function* expand(paths) {
  for (const given of paths) {
    const file = path.resolve(given);
    const name = path.basename(file);
    let stats;
    try {
      stats = await stat(file);
    } catch {
      yield { file, relativePath: name, unreadable: true };
      continue;
    }
    if (stats.isDirectory()) {
      if (!isHidden(name)) yield* walk(file, name);
    } else if (stats.isFile()) {
      yield { file, relativePath: name, size: stats.size };
    }
  }
}

/**
 * @param {string[]} paths absolute paths of dropped/picked files and folders
 * @param {Set<string>} known source paths already in the list
 * @returns {Promise<{accepted: {sourcePath, relativePath}[], rejected: {sourcePath, reason}[]}>}
 */
export const collectInputs = async (paths, known = new Set()) => {
  const accepted = [];
  const rejected = [];
  const seen = new Set(known);
  for await (const item of expand(paths)) {
    if (item.unreadable) {
      rejected.push({ sourcePath: item.file, reason: Rejection.Unreadable });
      continue;
    }
    let size = item.size;
    try {
      size ??= (await stat(item.file)).size;
    } catch {
      rejected.push({ sourcePath: item.file, reason: Rejection.Unreadable });
      continue;
    }
    const reason = classify(item.file, size, seen);
    if (reason) {
      rejected.push({ sourcePath: item.file, reason });
      continue;
    }
    seen.add(item.file);
    accepted.push({ sourcePath: item.file, relativePath: item.relativePath });
  }
  return { accepted, rejected };
};

const REASON_TEXT = {
  [Rejection.WrongType]: [
    "not a JPG/PNG/TIFF/WEBP file",
    "not JPG/PNG/TIFF/WEBP files",
  ],
  [Rejection.TooLarge]: ["larger than 200 MB", "larger than 200 MB"],
  [Rejection.AlreadyAdded]: ["already in the list", "already in the list"],
  [Rejection.Unreadable]: ["not readable", "not readable"],
};

/** The single summary remove.bg shows after a drop, or null if all were added. */
export const describeRejections = (addedCount, rejected) => {
  if (rejected.length === 0) return null;
  const plural = rejected.length !== 1;
  const reasons = [...new Set(rejected.map(({ reason }) => reason))]
    .map((reason) => REASON_TEXT[reason][plural ? 1 : 0])
    .join(" and/or ");
  const subject = plural ? "they are" : "it is";
  const count = `${rejected.length} image${plural ? "s" : ""}`;
  if (addedCount === 0) {
    return `Could not add ${count} because ${subject} ${reasons}.`;
  }
  const added = `${addedCount} image${addedCount === 1 ? "" : "s"}`;
  return `${added} added, but ${count} could not be added because ${subject} ${reasons}.`;
};
