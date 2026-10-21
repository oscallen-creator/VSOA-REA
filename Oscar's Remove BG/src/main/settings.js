// Persisted settings, mirroring remove.bg desktop 3.0.0's eight electron-settings
// keys and defaults (account and design-template keys dropped: this app is
// local). Stored as JSON in <userData>/settings.json; unknown or invalid
// values fall back to the default instead of failing startup.

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export const BG_MODES = Object.freeze(["transparent", "color"]);
export const SIZES = Object.freeze(["auto", "preview", "full"]);
export const SHADOWS = Object.freeze(["none", "auto", "car", "3D", "drop"]);
export const QUALITIES = Object.freeze(["best", "fast"]);
/** The ten quick colors remove.bg offers next to its color picker. */
export const PALETTE = Object.freeze([
  "#FFFFFF",
  "#000000",
  "#4E6A78",
  "#FAE92E",
  "#C3D72D",
  "#2BB0CA",
  "#303AA5",
  "#8900A1",
  "#E10051",
  "#EE292A",
]);
/** Opacity a shadow resets to when it is chosen ("auto" means mixed). */
export const SHADOW_DEFAULT_OPACITY = Object.freeze({
  none: "none",
  auto: "auto",
  car: 90,
  "3D": 50,
  drop: 50,
});

const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

export const defaultSettings = ({ picturesDir }) => ({
  outputPath: path.join(picturesDir, "Oscar's Remove BG"),
  usePsd: false,
  shadow: "none",
  shadowOpacity: "none",
  bgMode: "transparent",
  bgColor: "#FFFFFF",
  size: "auto",
  quality: "best",
});

const isOpacity = (value) =>
  value === "none" ||
  value === "auto" ||
  (Number.isInteger(value) && value >= 0 && value <= 100);

const VALIDATORS = {
  outputPath: (value) =>
    typeof value === "string" && path.isAbsolute(value) ? value : undefined,
  usePsd: (value) => (typeof value === "boolean" ? value : undefined),
  shadow: (value) => (SHADOWS.includes(value) ? value : undefined),
  shadowOpacity: (value) => (isOpacity(value) ? value : undefined),
  bgMode: (value) => (BG_MODES.includes(value) ? value : undefined),
  bgColor: (value) =>
    typeof value === "string" && HEX_COLOR.test(value)
      ? value.toUpperCase()
      : undefined,
  // remove.bg stored "50MP" for its Full Size option.
  size: (value) =>
    value === "50MP" ? "full" : SIZES.includes(value) ? value : undefined,
  quality: (value) => (QUALITIES.includes(value) ? value : undefined),
};

/** Keeps the valid known keys of `patch`; everything else is dropped. */
export const sanitizeSettings = (patch) => {
  const clean = {};
  if (typeof patch !== "object" || patch === null) return clean;
  for (const [key, validate] of Object.entries(VALIDATORS)) {
    if (!Object.hasOwn(patch, key)) continue;
    const value = validate(patch[key]);
    if (value !== undefined) clean[key] = value;
  }
  return clean;
};

/** Applies a patch the way remove.bg's controls do. */
export const applySettingsPatch = (current, patch) => {
  const clean = sanitizeSettings(patch);
  const next = { ...current, ...clean };
  // Choosing a shadow resets its opacity to that shadow's default.
  if (clean.shadow !== undefined && clean.shadowOpacity === undefined) {
    next.shadowOpacity = SHADOW_DEFAULT_OPACITY[clean.shadow];
  }
  if (next.shadow === "none") next.shadowOpacity = "none";
  if (next.shadow !== "auto" && next.shadowOpacity === "auto") {
    next.shadowOpacity = SHADOW_DEFAULT_OPACITY[next.shadow];
  }
  return next;
};

export const createSettingsStore = ({ file, defaults }) => {
  let current = { ...defaults };

  const load = async () => {
    try {
      const saved = JSON.parse(await readFile(file, "utf8"));
      current = { ...defaults, ...sanitizeSettings(saved) };
    } catch (error) {
      // A missing or corrupt file means defaults; never block startup.
      if (error?.code !== "ENOENT") {
        console.warn(`Ignoring unreadable settings ${file}: ${error.message}`);
      }
      current = { ...defaults };
    }
    return current;
  };

  const save = async () => {
    await mkdir(path.dirname(file), { recursive: true });
    const temporary = `${file}.${process.pid}.tmp`;
    await writeFile(temporary, JSON.stringify(current, null, 2));
    await rename(temporary, file);
  };

  const update = async (patch) => {
    current = applySettingsPatch(current, patch);
    await save();
    return current;
  };

  return { load, update, get: () => current };
};
