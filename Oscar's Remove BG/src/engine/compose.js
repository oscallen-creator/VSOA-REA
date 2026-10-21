// Turns the original pixels plus a segmentation alpha mask into the final
// output image, following the public remove.bg API semantics: ROI, subject
// box, crop / scale / position, size cap, shadow, background, channels,
// encoding. Options arrive already normalized and are never modified.

import sharp from "sharp";
import { encodePsd } from "./psd.js";
import { SHADOW_STYLES, renderShadow } from "./shadow.js";
import { createZip } from "./zip.js";

/** Pixels at or above this alpha count as subject when boxing it. */
export const SUBJECT_ALPHA_THRESHOLD = 10;

const MAX_PIXELS = Object.freeze({
  preview: 250_000,
  full: 50_000_000,
  auto: 50_000_000,
});
const MAX_MARGIN_PX = 500;
const CENTER = Object.freeze({ x: 0.5, y: 0.5 });
const WHITE = Object.freeze({ r: 255, g: 255, b: 255, alpha: 1 });

const PNG_COMPRESSION_LEVEL = 6;
// remove.bg exports its JPEGs at 0.92 from a canvas.
export const JPEG_QUALITY = 92;
const WEBP_QUALITY = 90;
const WEBP_ALPHA_QUALITY = 100;

const CHANNELS = ["rgba", "alpha"];
const FORMATS = ["auto", "png", "jpg", "webp", "zip", "psd"];
const PSD_MIME = "image/vnd.adobe.photoshop";
const SHADOW_TYPES = ["none", ...Object.keys(SHADOW_STYLES)];

export class ForegroundError extends Error {
  constructor() {
    super("Could not identify foreground in image.");
    this.name = "ForegroundError";
    this.code = "unknown_foreground";
  }
}

const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

const toPixels = ({ value, unit }, total) =>
  Math.round(unit === "%" ? (value / 100) * total : value);

// --- 1. ROI -----------------------------------------------------------------

/** Zeroes alpha outside the ROI. Returns a new array; the input is untouched. */
export const applyRoi = (alpha, roi, width, height) => {
  if (!roi) return alpha;
  const [x1, y1, x2, y2] = roi;
  const left = clamp(toPixels(x1, width), 0, width);
  const right = Math.max(left, clamp(toPixels(x2, width), 0, width));
  const top = clamp(toPixels(y1, height), 0, height);
  const bottom = clamp(toPixels(y2, height), 0, height);

  const masked = new Uint8Array(alpha.length);
  for (let y = top; y < bottom; y++) {
    const row = y * width;
    masked.set(alpha.subarray(row + left, row + right), row + left);
  }
  return masked;
};

// --- 2. Subject box -----------------------------------------------------------

// Null when no pixel reaches the threshold.
const scanSubjectBox = (alpha, width, height) => {
  let minX = width;
  let maxX = -1;
  let minY = height;
  let maxY = -1;
  for (let y = 0; y < height; y++) {
    const row = y * width;
    let first = -1;
    let last = -1;
    for (let x = 0; x < width; x++) {
      if (alpha[row + x] < SUBJECT_ALPHA_THRESHOLD) continue;
      if (first < 0) first = x;
      last = x;
    }
    if (first < 0) continue;
    minX = Math.min(minX, first);
    maxX = Math.max(maxX, last);
    minY = Math.min(minY, y);
    maxY = y;
  }
  if (maxY < 0) return null;
  return {
    left: minX,
    top: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  };
};

export const findSubjectBox = (alpha, width, height) => {
  const box = scanSubjectBox(alpha, width, height);
  if (box === null) throw new ForegroundError();
  return box;
};

// --- 3. Geometry --------------------------------------------------------------
// A plan says which source rectangle to draw (`region`), at what size
// (`drawn`), where its top-left lands on the output canvas (`at`, may be
// negative or overflow; content outside the canvas is clipped) and how big
// the canvas is. Everything the plan leaves uncovered stays transparent.

const wholeImage = (width, height) => ({
  canvas: { width, height },
  region: { left: 0, top: 0, width, height },
  drawn: { width, height },
  at: { left: 0, top: 0 },
});

// Percent margins follow the subject, not the image, and are capped so a huge
// margin cannot dwarf the subject.
const marginPx = ({ value, unit }, subjectLength) => {
  const wanted = unit === "%" ? (value / 100) * subjectLength : value;
  const cap = Math.min(subjectLength / 2, MAX_MARGIN_PX);
  return Math.round(clamp(wanted, 0, cap));
};

const planCrop = (box, width, height, cropMargin) => {
  const top = marginPx(cropMargin.top, box.height);
  const right = marginPx(cropMargin.right, box.width);
  const bottom = marginPx(cropMargin.bottom, box.height);
  const left = marginPx(cropMargin.left, box.width);
  const canvas = {
    width: left + box.width + right,
    height: top + box.height + bottom,
  };

  // The canvas is a window onto the source; where it sticks out past the
  // image edges there is nothing to draw, so those margins stay transparent.
  const originX = box.left - left;
  const originY = box.top - top;
  const x0 = Math.max(0, originX);
  const y0 = Math.max(0, originY);
  const x1 = Math.min(width, originX + canvas.width);
  const y1 = Math.min(height, originY + canvas.height);
  const region = { left: x0, top: y0, width: x1 - x0, height: y1 - y0 };
  return {
    canvas,
    region,
    drawn: { width: region.width, height: region.height },
    at: { left: x0 - originX, top: y0 - originY },
  };
};

// CSS background-position semantics: 0 aligns the start edges, 1 the end edges.
const place = (fraction, canvasLength, subjectLength) =>
  Math.round(fraction * (canvasLength - subjectLength));

const planPlacement = (box, width, height, { scale, position }) => {
  const factor =
    scale === null
      ? 1
      : scale * Math.min(width / box.width, height / box.height);
  const drawn = {
    width: Math.max(1, Math.round(box.width * factor)),
    height: Math.max(1, Math.round(box.height * factor)),
  };
  const { x, y } = position ?? CENTER;
  return {
    canvas: { width, height },
    region: box,
    drawn,
    at: {
      left: place(x, width, drawn.width),
      top: place(y, height, drawn.height),
    },
  };
};

export const planGeometry = ({ box, width, height, options }) => {
  if (options.crop) return planCrop(box, width, height, options.cropMargin);
  if (options.scale !== null || options.position !== null) {
    return planPlacement(box, width, height, options);
  }
  return wholeImage(width, height);
};

// --- 4. Size ------------------------------------------------------------------

export const fitToMaxPixels = ({ width, height }, maxPixels) => {
  if (width * height <= maxPixels) return { width, height };
  const ratio = Math.sqrt(maxPixels / (width * height));
  return {
    width: Math.max(1, Math.floor(width * ratio)),
    height: Math.max(1, Math.floor(height * ratio)),
  };
};

// --- Pixel plumbing ---------------------------------------------------------------

const rawInput = (data, { width, height }, channels) =>
  sharp(data, { raw: { width, height, channels } });

// sharp premultiplies RGBA before resampling, so transparent pixels do not
// bleed their colour into the edge of the subject.
const resizeRgba = async (data, from, to) =>
  rawInput(data, from, 4)
    .resize(to.width, to.height, { kernel: "lanczos3", fit: "fill" })
    .raw()
    .toBuffer();

const extractRgba = (image, alpha, region) => {
  const out = Buffer.allocUnsafe(region.width * region.height * 4);
  let o = 0;
  for (let y = region.top; y < region.top + region.height; y++) {
    let source = y * image.width + region.left;
    for (let x = 0; x < region.width; x++, source++) {
      const i = source * 3;
      out[o++] = image.data[i];
      out[o++] = image.data[i + 1];
      out[o++] = image.data[i + 2];
      out[o++] = alpha[source];
    }
  }
  return out;
};

const extractRgb = (rgba) => {
  const out = Buffer.allocUnsafe((rgba.length / 4) * 3);
  for (let i = 0, o = 0; i < rgba.length; i += 4) {
    out[o++] = rgba[i];
    out[o++] = rgba[i + 1];
    out[o++] = rgba[i + 2];
  }
  return out;
};

const extractAlpha = (rgba) => {
  const out = Buffer.allocUnsafe(rgba.length / 4);
  for (let i = 0; i < out.length; i++) out[i] = rgba[i * 4 + 3];
  return out;
};

const hasTranslucency = (rgba) => {
  for (let i = 3; i < rgba.length; i += 4) if (rgba[i] < 255) return true;
  return false;
};

/** Copies the visible part of `source` onto `canvas` (both RGBA). */
const blit = (canvas, source, at) => {
  const x0 = Math.max(0, at.left);
  const x1 = Math.min(canvas.width, at.left + source.width);
  const y0 = Math.max(0, at.top);
  const y1 = Math.min(canvas.height, at.top + source.height);
  if (x1 <= x0 || y1 <= y0) return;
  for (let y = y0; y < y1; y++) {
    const from = ((y - at.top) * source.width + (x0 - at.left)) * 4;
    source.data.copy(
      canvas.data,
      (y * canvas.width + x0) * 4,
      from,
      from + (x1 - x0) * 4,
    );
  }
};

const renderCanvas = async (image, alpha, { canvas, region, drawn, at }) => {
  let data = extractRgba(image, alpha, region);
  if (drawn.width !== region.width || drawn.height !== region.height) {
    data = await resizeRgba(data, region, drawn);
  }
  const fillsCanvas =
    drawn.width === canvas.width &&
    drawn.height === canvas.height &&
    at.left === 0 &&
    at.top === 0;
  if (fillsCanvas) return { ...canvas, data };

  const rendered = {
    ...canvas,
    data: Buffer.alloc(canvas.width * canvas.height * 4),
  };
  blit(rendered, { ...drawn, data }, at);
  return rendered;
};

// --- 5. Shadow ----------------------------------------------------------------------

// The subject over a black layer of alpha `shadow / 255`, in straight alpha and
// in place. The layer has no colour, so only the subject adds to the colour.
const compositeShadow = (rgba, shadow) => {
  for (let i = 0, p = 0; p < shadow.length; i += 4, p++) {
    const layerAlpha = shadow[p] / 255;
    const a = rgba[i + 3];
    if (layerAlpha === 0 || a === 255) continue;
    const subjectAlpha = a / 255;
    const outAlpha = subjectAlpha + layerAlpha * (1 - subjectAlpha);
    const subjectWeight = subjectAlpha / outAlpha;
    rgba[i] = Math.round(rgba[i] * subjectWeight);
    rgba[i + 1] = Math.round(rgba[i + 1] * subjectWeight);
    rgba[i + 2] = Math.round(rgba[i + 2] * subjectWeight);
    rgba[i + 3] = Math.round(outAlpha * 255);
  }
};

// Shadow coverage cast by the canvas's cutout, or null. Callers that predate
// shadows pass options without the two fields.
const castShadow = async (
  canvas,
  { shadowType = "none", shadowOpacity = 0 },
) => {
  if (shadowType === "none" || shadowOpacity === 0) return null;
  const alpha = extractAlpha(canvas.data);
  // A downscale can leave no pixel above the threshold; nothing to cast from.
  const box = scanSubjectBox(alpha, canvas.width, canvas.height);
  if (box === null) return null;
  return renderShadow({
    alpha,
    width: canvas.width,
    height: canvas.height,
    box,
    type: shadowType,
    opacity: shadowOpacity,
  });
};

const applyShadow = async (canvas, options) => {
  const shadow = await castShadow(canvas, options);
  if (shadow !== null) compositeShadow(canvas.data, shadow);
};

// --- 6. Background ------------------------------------------------------------------

// Source-over in straight alpha, in place. `canvas` is always our own buffer.
const compositeOverColor = (rgba, { r, g, b, alpha: backdropAlpha }) => {
  const backdrop255 = Math.round(backdropAlpha * 255);
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    if (a === 255) continue;
    if (a === 0) {
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = backdrop255;
      continue;
    }
    const subjectAlpha = a / 255;
    const outAlpha = subjectAlpha + backdropAlpha * (1 - subjectAlpha);
    const subjectWeight = subjectAlpha / outAlpha;
    const backdropWeight = 1 - subjectWeight;
    rgba[i] = Math.round(rgba[i] * subjectWeight + r * backdropWeight);
    rgba[i + 1] = Math.round(rgba[i + 1] * subjectWeight + g * backdropWeight);
    rgba[i + 2] = Math.round(rgba[i + 2] * subjectWeight + b * backdropWeight);
    rgba[i + 3] = Math.round(outAlpha * 255);
  }
};

const compositeOverImage = (rgba, backdropRgb) => {
  for (let i = 0, p = 0; i < rgba.length; i += 4, p += 3) {
    const a = rgba[i + 3];
    if (a === 255) continue;
    for (let c = 0; c < 3; c++) {
      rgba[i + c] = Math.round(
        (rgba[i + c] * a + backdropRgb[p + c] * (255 - a)) / 255,
      );
    }
    rgba[i + 3] = 255;
  }
};

// The backdrop is opaque: its own transparency is flattened over white first.
const loadBackdrop = async (bytes, { width, height }) => {
  try {
    const { data, info } = await sharp(bytes)
      .rotate()
      .flatten({ background: WHITE })
      .resize(width, height, { fit: "cover", kernel: "lanczos3" })
      .toColourspace("srgb")
      .removeAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    if (info.channels !== 3) {
      throw new Error(`unexpected ${info.channels}-channel result`);
    }
    return data;
  } catch (error) {
    throw new Error(`Could not use the background image: ${error.message}`, {
      cause: error,
    });
  }
};

// An image backdrop is opaque and would hide any colour, so it wins.
const applyBackground = async (canvas, { bgColor, bgImage }) => {
  if (bgImage) {
    compositeOverImage(canvas.data, await loadBackdrop(bgImage, canvas));
  } else if (bgColor) {
    compositeOverColor(canvas.data, bgColor);
  }
};

// --- 7./8. Channels and encoding --------------------------------------------------

// The input's DPI as the whole number remove.bg writes; null writes none.
const toDpi = (density) => {
  if (density === undefined || density === null) return null;
  if (!(Number.isFinite(density) && density > 0)) {
    throw new Error(`Invalid density ${density}; expected a positive number.`);
  }
  return Math.max(1, Math.round(density));
};

const withDpi = (image, dpi) => (dpi === null ? image : image.withDensity(dpi));

// A browser canvas keeps premultiplied alpha, so remove.bg's PNG has RGB 0
// wherever nothing shows. Doing the same keeps the removed background out of the
// file.
const clearHiddenColor = (rgba) => {
  for (let i = 3; i < rgba.length; i += 4) {
    if (rgba[i] !== 0) continue;
    rgba[i - 3] = 0;
    rgba[i - 2] = 0;
    rgba[i - 1] = 0;
  }
};

// sharp writes 1-channel raw input as RGB unless told it is grayscale.
const encodeAlphaPng = (canvas, dpi) =>
  withDpi(rawInput(extractAlpha(canvas.data), canvas, 1), dpi)
    .toColourspace("b-w")
    .png({ compressionLevel: PNG_COMPRESSION_LEVEL })
    .toBuffer();

// Takes the colour channels as they are; callers flatten first when needed.
const encodeColorJpeg = (canvas, dpi) =>
  withDpi(rawInput(extractRgb(canvas.data), canvas, 3), dpi)
    .jpeg({ quality: JPEG_QUALITY })
    .toBuffer();

const ENCODERS = {
  png: {
    mime: "image/png",
    encode: (canvas, dpi) => {
      clearHiddenColor(canvas.data);
      return withDpi(rawInput(canvas.data, canvas, 4), dpi)
        .png({ compressionLevel: PNG_COMPRESSION_LEVEL })
        .toBuffer();
    },
  },
  webp: {
    mime: "image/webp",
    encode: (canvas, dpi) => {
      clearHiddenColor(canvas.data);
      return withDpi(rawInput(canvas.data, canvas, 4), dpi)
        .webp({ quality: WEBP_QUALITY, alphaQuality: WEBP_ALPHA_QUALITY })
        .toBuffer();
    },
  },
  jpg: {
    mime: "image/jpeg",
    encode: (canvas, dpi) => {
      compositeOverColor(canvas.data, WHITE);
      return encodeColorJpeg(canvas, dpi);
    },
  },
  zip: {
    mime: "application/zip",
    // color.jpg keeps the colours of the final canvas unflattened; the cutout
    // lives in alpha.png.
    encode: async (canvas, dpi) => {
      const [color, alpha] = await Promise.all([
        encodeColorJpeg(canvas, dpi),
        encodeAlphaPng(canvas, dpi),
      ]);
      return createZip([
        { name: "color.jpg", data: color },
        { name: "alpha.png", data: alpha },
      ]);
    },
  },
};

// Photoshop gets the cutout, its shadow and the background as separate layers,
// like remove.bg's PSD, so the mask stays editable.
const encodeLayeredPsd = async (canvas, options, dpi) => {
  if (options.bgImage) {
    throw new Error(
      "PSD output takes a background colour, not a background image.",
    );
  }
  const color = extractRgb(canvas.data);
  const { bgColor } = options;
  return encodePsd({
    width: canvas.width,
    height: canvas.height,
    color,
    alpha: extractAlpha(canvas.data),
    original: color,
    shadow: await castShadow(canvas, options),
    background: bgColor && { r: bgColor.r, g: bgColor.g, b: bgColor.b },
    density: dpi,
  });
};

const resolveFormat = (format, canvas) => {
  if (format !== "auto") return format;
  return hasTranslucency(canvas.data) ? "png" : "jpg";
};

// --- compose ------------------------------------------------------------------------

const assertOneOf = (name, value, allowed) => {
  if (!allowed.includes(value)) {
    throw new Error(`Unknown ${name} ${JSON.stringify(value)}.`);
  }
};

const assertInputs = ({ image, alpha, options }) => {
  const { data, width, height, channels } = image;
  if (channels !== 3 || data.length !== width * height * 3) {
    throw new Error(`Expected raw RGB pixels for a ${width}x${height} image.`);
  }
  if (alpha.length !== width * height) {
    throw new Error(
      `Alpha mask has ${alpha.length} values; expected ${width * height}.`,
    );
  }
  assertOneOf("size", options.size, Object.keys(MAX_PIXELS));
  assertOneOf("format", options.format, FORMATS);
  assertOneOf("channels", options.channels, CHANNELS);
  assertOneOf("shadow type", options.shadowType ?? "none", SHADOW_TYPES);
  if (options.channels === "alpha" && options.format === "zip") {
    throw new Error(
      'format "zip" cannot be combined with channels "alpha"; ask for png, jpg, webp or auto.',
    );
  }
};

/**
 * @param {object} args
 * @param {number | null} [args.density] the input's DPI; written into the
 *   output when set, left out when not
 */
export const compose = async ({ image, alpha, options, density = null }) => {
  assertInputs({ image, alpha, options });
  const dpi = toDpi(density);
  const { width, height } = image;

  const masked = applyRoi(alpha, options.roi, width, height);
  const subjectBox = findSubjectBox(masked, width, height);
  const plan = planGeometry({ box: subjectBox, width, height, options });
  const size = fitToMaxPixels(plan.canvas, MAX_PIXELS[options.size]);

  let canvas = await renderCanvas(image, masked, plan);
  if (size.width !== canvas.width || size.height !== canvas.height) {
    canvas = { ...size, data: await resizeRgba(canvas.data, canvas, size) };
  }

  const finish = (buffer, format, mime = ENCODERS[format].mime) => ({
    buffer,
    format,
    mime,
    width: canvas.width,
    height: canvas.height,
    subjectBox,
  });

  if (options.format === "psd" && options.channels === "rgba") {
    const psd = await encodeLayeredPsd(canvas, options, dpi);
    return finish(psd, "psd", PSD_MIME);
  }

  // The shadow is part of the cutout: the matte and the zip's files include it.
  await applyShadow(canvas, options);

  // A matte ignores any background: it is the cutout's own alpha.
  if (options.channels === "alpha") {
    return finish(await encodeAlphaPng(canvas, dpi), "png");
  }

  await applyBackground(canvas, options);
  const format = resolveFormat(options.format, canvas);
  return finish(await ENCODERS[format].encode(canvas, dpi), format);
};
