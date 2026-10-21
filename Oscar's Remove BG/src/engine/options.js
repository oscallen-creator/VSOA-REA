// Options mirror the public remove.bg API parameters so callers can reuse the
// same settings. Values usually arrive as strings (CLI flags, HTTP forms), so
// each one is parsed and normalized once here; later stages only see the result.

export class OptionError extends Error {
  code = "invalid_option";

  constructor(parameter, message) {
    super(message);
    this.name = "OptionError";
    /** The snake_case parameter name, e.g. "crop_margin". */
    this.parameter = parameter;
  }
}

const PARAMETERS = new Set([
  "size",
  "format",
  "channels",
  "type",
  "bg_color",
  "bg_image",
  "crop",
  "crop_margin",
  "scale",
  "position",
  "roi",
  "shadow_type",
  "shadow_opacity",
]);

const choices = (names, aliases = {}) =>
  new Map([...names.map((name) => [name, name]), ...Object.entries(aliases)]);

const SIZES = choices(["auto", "preview", "full"], {
  small: "preview",
  regular: "preview",
  medium: "full",
  hd: "full",
  "4k": "full",
});
const FORMATS = choices(["auto", "png", "jpg", "webp", "zip", "psd"], {
  jpeg: "jpg",
});
const CHANNELS = choices(["rgba", "alpha"]);
// No local model specializes on these; remove.bg accepts them, so we do too.
const TYPES = choices(["auto", "person", "product"], {
  car: "auto",
  animal: "auto",
  graphic: "auto",
  transportation: "auto",
});

// "3D" is the only mixed-case name; input is lowercased before the lookup.
const SHADOW_TYPES = new Map(
  ["none", "auto", "car", "3D", "drop"].map((name) => [
    name.toLowerCase(),
    name,
  ]),
);
// What remove.bg's UI picks when the shadow type changes. Its "auto" opacity is
// 90 for cars and 50 for anything else; cars cannot be told apart here.
const SHADOW_DEFAULT_OPACITY = Object.freeze({
  none: 0,
  auto: 0.5,
  car: 0.9,
  "3D": 0.5,
  drop: 0.5,
});

const BOOLEANS = new Map([
  ["true", true],
  ["1", true],
  ["false", false],
  ["0", false],
]);

const NAMED_COLORS = new Map([
  ["black", "000000"],
  ["white", "ffffff"],
  ["red", "ff0000"],
  ["green", "008000"],
  ["blue", "0000ff"],
  ["yellow", "ffff00"],
  ["gray", "808080"],
  ["grey", "808080"],
  ["orange", "ffa500"],
  ["purple", "800080"],
  ["pink", "ffc0cb"],
  ["cyan", "00ffff"],
  ["magenta", "ff00ff"],
  ["brown", "a52a2a"],
  ["transparent", "00000000"],
]);

const HEX_COLOR = /^#?([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/;
const LENGTH = /^(-?(?:\d+(?:\.\d+)?|\.\d+))(px|%)?$/i;
const SCALE = /^(\d+(?:\.\d+)?|\.\d+)%?$/;
const PERCENT = /^(\d+(?:\.\d+)?|\.\d+)%$/;

const isAbsent = (value) => value === undefined || value === null;

const show = (value) => {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value !== "object" || value === null) return String(value);
  return Array.isArray(value) ? "an array" : "an object";
};

const invalid = (parameter, value, reason) =>
  new OptionError(parameter, `Invalid ${parameter} ${show(value)}: ${reason}`);

const splitWords = (text) => {
  const trimmed = text.trim();
  return trimmed === "" ? [] : trimmed.split(/\s+/);
};

const choiceParser = (parameter, accepted, fallback) => (value) => {
  if (isAbsent(value)) return fallback;
  const match =
    typeof value === "string"
      ? accepted.get(value.trim().toLowerCase())
      : undefined;
  if (match === undefined) {
    const names = [...new Set(accepted.values())].join(", ");
    throw invalid(parameter, value, `expected one of ${names}`);
  }
  return match;
};

const parseSize = choiceParser("size", SIZES, "auto");
const parseFormat = choiceParser("format", FORMATS, "auto");
const parseChannels = choiceParser("channels", CHANNELS, "rgba");
const parseType = choiceParser("type", TYPES, "auto");
const parseShadowType = choiceParser("shadow_type", SHADOW_TYPES, "none");

const parseCrop = (value) => {
  if (isAbsent(value)) return false;
  if (typeof value === "boolean") return value;
  const parsed =
    typeof value === "string"
      ? BOOLEANS.get(value.trim().toLowerCase())
      : undefined;
  if (parsed === undefined) {
    throw invalid("crop", value, 'expected true, false, "1" or "0"');
  }
  return parsed;
};

const colorFromHex = (digits) => {
  const full =
    digits.length <= 4
      ? [...digits].map((digit) => digit + digit).join("")
      : digits;
  const channel = (index) => parseInt(full.slice(index * 2, index * 2 + 2), 16);
  return {
    r: channel(0),
    g: channel(1),
    b: channel(2),
    alpha: full.length === 8 ? channel(3) / 255 : 1,
  };
};

/** Hex (3, 4, 6 or 8 digits, `#` optional) or a color name; empty means none. */
export const parseColor = (value) => {
  if (isAbsent(value)) return null;
  if (typeof value !== "string") {
    throw invalid("bg_color", value, "expected a hex color or a color name");
  }
  const text = value.trim().toLowerCase();
  if (text === "") return null;
  const digits = NAMED_COLORS.get(text) ?? HEX_COLOR.exec(text)?.[1];
  if (digits === undefined) {
    throw invalid(
      "bg_color",
      value,
      "expected a hex color (3, 4, 6 or 8 digits) or a color name",
    );
  }
  return colorFromHex(digits);
};

const parseBgImage = (value) => {
  if (isAbsent(value)) return null;
  if (Buffer.isBuffer(value)) return value;
  // A view, not a copy: the bytes stay the caller's and are never decoded here.
  if (value instanceof Uint8Array) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  }
  throw invalid("bg_image", value, "expected a Buffer or Uint8Array");
};

/** `"<number>px"`, `"<number>%"`, or a bare number (px). Never negative. */
export const parseLength = (value, parameter = "length") => {
  const match = typeof value === "string" ? LENGTH.exec(value.trim()) : null;
  const number =
    typeof value === "number"
      ? value
      : match === null
        ? Number.NaN
        : Number(match[1]);
  if (!Number.isFinite(number)) {
    throw invalid(
      parameter,
      value,
      'expected a number with an optional "px" or "%" unit',
    );
  }
  if (number < 0) throw invalid(parameter, value, "must not be negative");
  // Math.abs folds -0 into 0 so results compare cleanly.
  return { value: Math.abs(number), unit: match?.[2]?.toLowerCase() ?? "px" };
};

/**
 * CSS-like shorthand: 1 value = all sides, 2 = top/bottom then left/right,
 * 4 = top right bottom left. Values are kept as given; the per-side cap is the
 * compositor's job because it depends on the image.
 */
export const parseMargin = (value) => {
  const tokens =
    typeof value === "string"
      ? splitWords(value)
      : typeof value === "number"
        ? [value]
        : isAbsent(value)
          ? [0]
          : [];
  if (![1, 2, 4].includes(tokens.length)) {
    throw invalid("crop_margin", value, "expected 1, 2 or 4 lengths");
  }
  const lengths = tokens.map((token) => parseLength(token, "crop_margin"));
  const [top, right = top, bottom = top, left = right] = lengths;
  return {
    top: { ...top },
    right: { ...right },
    bottom: { ...bottom },
    left: { ...left },
  };
};

const percentFromString = (value) => {
  if (typeof value === "number") return value;
  if (typeof value !== "string") return Number.NaN;
  const match = SCALE.exec(value.trim());
  return match === null ? Number.NaN : Number(match[1]);
};

/** "original" (null) or 10%..100% as a fraction; a bare number is a percent. */
export const parseScale = (value) => {
  if (isAbsent(value)) return null;
  if (typeof value === "string" && value.trim().toLowerCase() === "original") {
    return null;
  }
  const percent = percentFromString(value);
  // NaN fails both comparisons, so malformed input lands here too.
  if (!(percent >= 10 && percent <= 100)) {
    throw invalid("scale", value, 'expected "original" or 10% to 100%');
  }
  return percent / 100;
};

/** "original" (null), "center", or `x% [y%]`; one percentage sets both axes. */
export const parsePosition = (value) => {
  if (isAbsent(value)) return null;
  const text = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (text === "original") return null;
  if (text === "center") return { x: 0.5, y: 0.5 };
  const tokens = splitWords(text);
  const percents = tokens.map((token) => PERCENT.exec(token)?.[1]);
  if (
    ![1, 2].includes(tokens.length) ||
    percents.some((percent) => percent === undefined || Number(percent) > 100)
  ) {
    throw invalid(
      "position",
      value,
      'expected "original", "center", or one or two percentages from 0% to 100%',
    );
  }
  const [x, y = x] = percents.map((percent) => Number(percent) / 100);
  return { x, y };
};

/**
 * 0% to 100% as a fraction; unset, "auto", "none" or "" mean the default for
 * the shadow type. A bare number is a percent, as in remove.bg's form.
 */
const parseShadowOpacity = (value, shadowType) => {
  const word = typeof value === "string" ? value.trim().toLowerCase() : null;
  if (isAbsent(value) || ["", "auto", "none"].includes(word)) {
    return SHADOW_DEFAULT_OPACITY[shadowType];
  }
  const percent = percentFromString(value);
  // NaN fails both comparisons, so malformed input lands here too.
  if (!(percent >= 0 && percent <= 100)) {
    throw invalid("shadow_opacity", value, 'expected "auto" or 0% to 100%');
  }
  return percent / 100;
};

// Lengths in different units cannot be compared without the image size.
const isOrdered = (from, to) => from.unit !== to.unit || to.value > from.value;

/** Region of interest as `x1 y1 x2 y2`, or null for the whole image. */
export const parseRoi = (value) => {
  if (isAbsent(value)) return null;
  const tokens = typeof value === "string" ? splitWords(value) : [];
  if (tokens.length !== 4) {
    throw invalid("roi", value, 'expected four lengths "x1 y1 x2 y2"');
  }
  const roi = tokens.map((token) => parseLength(token, "roi"));
  if (roi.some(({ value: amount, unit }) => unit === "%" && amount > 100)) {
    throw invalid("roi", value, "percentages must be 0% to 100%");
  }
  const [x1, y1, x2, y2] = roi;
  if (!isOrdered(x1, x2) || !isOrdered(y1, y2)) {
    throw invalid("roi", value, "x2 and y2 must be greater than x1 and y1");
  }
  return roi;
};

const isPlainObject = (value) => {
  if (typeof value !== "object" || value === null) return false;
  const prototype = Object.getPrototypeOf(value);
  // querystring.parse() returns null-prototype objects.
  return prototype === Object.prototype || prototype === null;
};

const toSnakeCase = (key) =>
  key.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);

// Maps snake_case parameter -> value, accepting either spelling of each key.
// Unset (undefined/null) values are left out so they fall back to defaults.
const collectGiven = (raw) => {
  if (!isPlainObject(raw)) {
    throw invalid("options", raw, "expected an object of option values");
  }
  const given = new Map();
  for (const [key, value] of Object.entries(raw)) {
    const parameter = toSnakeCase(key);
    if (!PARAMETERS.has(parameter)) {
      // Echo the key as sent: there is no known snake_case name to report.
      throw new OptionError(key, `Unknown option ${JSON.stringify(key)}`);
    }
    if (isAbsent(value)) continue;
    if (given.has(parameter)) {
      throw new OptionError(
        parameter,
        `Option ${parameter} was given more than once (camelCase and snake_case)`,
      );
    }
    given.set(parameter, value);
  }
  return given;
};

// Buffers cannot be frozen (typed arrays with elements), and are the caller's.
const freezeDeep = (value) => {
  if (typeof value !== "object" || value === null) return value;
  if (ArrayBuffer.isView(value)) return value;
  Object.values(value).forEach(freezeDeep);
  return Object.freeze(value);
};

/**
 * Parses raw option values into the frozen shape the compositor reads:
 *
 *     size, format, channels, type: canonical strings (see the choices above)
 *     bgColor        { r, g, b, alpha 0..1 } | null
 *     bgImage        Buffer | null (undecoded)
 *     crop           boolean
 *     cropMargin     { top, right, bottom, left }, each { value, unit }
 *     scale          0.1..1 | null (original)
 *     position       { x, y } 0..1 | null (original)
 *     roi            [x1, y1, x2, y2], each { value, unit } | null
 *     shadowType     "none" | "auto" | "car" | "3D" | "drop"
 *     shadowOpacity  0..1, resolved to the type's default when not given
 *
 * `unit` is "px" or "%".
 */
export const parseOptions = (raw = {}) => {
  const given = collectGiven(raw ?? {});

  const bgColor = parseColor(given.get("bg_color"));
  const bgImage = parseBgImage(given.get("bg_image"));
  if (bgColor !== null && bgImage !== null) {
    throw invalid(
      "bg_color",
      given.get("bg_color"),
      "cannot be combined with bg_image; only one bg_ parameter is allowed",
    );
  }

  const scale = parseScale(given.get("scale"));
  // remove.bg: scaling the subject implies position=center unless specified.
  const position = parsePosition(
    given.get("position") ?? (scale === null ? undefined : "center"),
  );

  const shadowType = parseShadowType(given.get("shadow_type"));

  return freezeDeep({
    size: parseSize(given.get("size")),
    format: parseFormat(given.get("format")),
    channels: parseChannels(given.get("channels")),
    type: parseType(given.get("type")),
    bgColor,
    bgImage,
    crop: parseCrop(given.get("crop")),
    cropMargin: parseMargin(given.get("crop_margin")),
    scale,
    position,
    roi: parseRoi(given.get("roi")),
    shadowType,
    shadowOpacity: parseShadowOpacity(given.get("shadow_opacity"), shadowType),
  });
};
