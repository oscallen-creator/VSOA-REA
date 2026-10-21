// Encodes a cutout as a layered Photoshop file, like remove.bg's "Photoshop
// file" download: the full colour image sits on top with the cutout as an
// editable layer mask, with the original, an optional background colour and an
// optional shadow below it. The flattened composite (what viewers without
// layer support show) is background + shadow + cutout.
//
// Pure function over raw pixels: it never touches the file system and never
// initialises ag-psd's canvas support, so it works in plain Node.

import { writePsdBuffer } from "ag-psd";

/** Photoshop's PSD (not PSB) limit for each side of the document. */
export const MAX_PSD_SIZE = 30_000;
/**
 * ag-psd 31.0.3 run-length encodes the flattened image into a scratch buffer
 * of 8 bytes a pixel, which a canvas 1 or 2 pixels wide can overflow; the file
 * is then silently cut short. Such outputs are refused instead.
 */
export const MIN_PSD_WIDTH = 3;

// Resolution is stored as 16.16 fixed point, which tops out just below 32768.
const MAX_DENSITY = 32_767;

const NAME = "Oscar's Remove BG";
export const LAYER_NAMES = Object.freeze({
  original: `${NAME} - Original Image`,
  background: `${NAME} - Background`,
  shadow: `${NAME} - Shadows`,
  cutout: NAME,
});

// --- Validation ---------------------------------------------------------------

const assertSide = (name, value) => {
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(
      `PSD ${name} must be a whole number of pixels, got ${value}.`,
    );
  }
  if (value > MAX_PSD_SIZE) {
    throw new Error(
      `PSD ${name} of ${value} px is over the Photoshop limit of ${MAX_PSD_SIZE} px.`,
    );
  }
};

const assertBytes = (name, data, expected) => {
  if (!ArrayBuffer.isView(data) || data.length !== expected) {
    throw new Error(
      `PSD ${name} has ${data?.length ?? "no"} values; expected ${expected}.`,
    );
  }
};

const assertBackground = (background) => {
  const channels = [background.r, background.g, background.b];
  if (!channels.every((v) => Number.isInteger(v) && v >= 0 && v <= 255)) {
    throw new Error("PSD background needs integer r, g and b of 0-255.");
  }
};

const assertDensity = (density) => {
  if (!Number.isFinite(density) || density <= 0 || density > MAX_DENSITY) {
    throw new Error(
      `PSD density must be 0-${MAX_DENSITY} DPI, got ${density}.`,
    );
  }
};

const assertInputs = (input) => {
  const { width, height, color, alpha, original, shadow } = input;
  assertSide("width", width);
  if (width < MIN_PSD_WIDTH) {
    throw new Error(
      `PSD output needs an image at least ${MIN_PSD_WIDTH} px wide, got ${width} px.`,
    );
  }
  assertSide("height", height);
  const pixels = width * height;
  assertBytes("colour data", color, pixels * 3);
  assertBytes("alpha mask", alpha, pixels);
  if (original) assertBytes("original image", original, pixels * 3);
  if (shadow) assertBytes("shadow mask", shadow, pixels);
  if (input.background) assertBackground(input.background);
  if (input.density !== null) assertDensity(input.density);
};

// --- Pixel buffers --------------------------------------------------------------
// ag-psd wants RGBA imageData even for a mask, so every raster is 4 bytes a pixel.

const opaqueRgba = (rgb) => {
  const out = new Uint8ClampedArray((rgb.length / 3) * 4);
  for (let i = 0, o = 0; i < rgb.length; i += 3, o += 4) {
    out[o] = rgb[i];
    out[o + 1] = rgb[i + 1];
    out[o + 2] = rgb[i + 2];
    out[o + 3] = 255;
  }
  return out;
};

const solidRgba = (count, { r, g, b }) => {
  const out = new Uint8ClampedArray(count * 4);
  for (let o = 0; o < out.length; o += 4) {
    out[o] = r;
    out[o + 1] = g;
    out[o + 2] = b;
    out[o + 3] = 255;
  }
  return out;
};

// Black pixels whose alpha is the coverage. Photoshop's own shadow is a vector
// fill whose fill opacity carries the strength; a raster layer looks the same,
// opens everywhere, and keeps the exact coverage, but the strength is baked
// into the alpha instead of being a slider.
const shadowRgba = (coverage) => {
  const out = new Uint8ClampedArray(coverage.length * 4);
  for (let i = 0; i < coverage.length; i++) out[i * 4 + 3] = coverage[i];
  return out;
};

// A layer mask is grey: white shows the layer, black hides it. ag-psd reads
// and writes only the first channel, but the grey is kept in R=G=B anyway.
const maskRgba = (alpha) => {
  const out = new Uint8ClampedArray(alpha.length * 4);
  for (let i = 0, o = 0; i < alpha.length; i++, o += 4) {
    out[o] = alpha[i];
    out[o + 1] = alpha[i];
    out[o + 2] = alpha[i];
    out[o + 3] = 255;
  }
  return out;
};

// --- Composite --------------------------------------------------------------------

// What lies beneath the cutout: the shadow over the background colour, or the
// shadow alone with its own alpha when there is no background.
const backdropRgba = ({ shadow, background }, pixels) => {
  if (!background) {
    return shadow ? shadowRgba(shadow) : new Uint8ClampedArray(pixels * 4);
  }
  const { r, g, b } = background;
  const out = solidRgba(pixels, background);
  if (!shadow) return out;
  for (let i = 0, o = 0; i < pixels; i++, o += 4) {
    const keep = 255 - shadow[i];
    out[o] = Math.round((r * keep) / 255);
    out[o + 1] = Math.round((g * keep) / 255);
    out[o + 2] = Math.round((b * keep) / 255);
  }
  return out;
};

// Straight-alpha source-over of cutout pixel `i` onto its backdrop, in place.
// Called for translucent pixels only, so the result always has alpha > 0.
const blendPixel = (out, color, alpha, i) => {
  const o = i * 4;
  const p = i * 3;
  const src = alpha[i] / 255;
  const below = out[o + 3] / 255;
  const outAlpha = src + below * (1 - src);
  const weight = below * (1 - src);
  for (let c = 0; c < 3; c++) {
    out[o + c] = Math.round(
      (color[p + c] * src + out[o + c] * weight) / outAlpha,
    );
  }
  out[o + 3] = Math.round(outAlpha * 255);
};

const compositeCutout = (out, color, alpha) => {
  for (let i = 0; i < alpha.length; i++) {
    const a = alpha[i];
    if (a === 0) continue;
    if (a !== 255) {
      blendPixel(out, color, alpha, i);
      continue;
    }
    out.set(color.subarray(i * 3, i * 3 + 3), i * 4);
    out[i * 4 + 3] = 255;
  }
};

const flatten = (input) => {
  const { width, height, color, alpha } = input;
  const data = backdropRgba(input, width * height);
  compositeCutout(data, color, alpha);
  return { width, height, data };
};

// --- Layers -----------------------------------------------------------------------

const rasterLayer = (name, { width, height }, data, extra = {}) => ({
  name,
  left: 0,
  top: 0,
  imageData: { width, height, data },
  ...extra,
});

// The full colour image with the cutout as a full-canvas, editable layer mask.
const cutoutLayer = (size, { color, alpha }) =>
  rasterLayer(LAYER_NAMES.cutout, size, opaqueRgba(color), {
    mask: {
      left: 0,
      top: 0,
      right: size.width,
      bottom: size.height,
      defaultColor: 0,
      imageData: { ...size, data: maskRgba(alpha) },
    },
  });

// Bottom to top: ag-psd writes `children` in file order, first child lowest.
const buildLayers = (size, input) => {
  const { original, shadow, background } = input;
  const pixels = size.width * size.height;
  const layers = [];
  if (original) {
    layers.push(
      rasterLayer(LAYER_NAMES.original, size, opaqueRgba(original), {
        hidden: true,
      }),
    );
  }
  if (background) {
    layers.push(
      rasterLayer(LAYER_NAMES.background, size, solidRgba(pixels, background)),
    );
  }
  if (shadow) {
    layers.push(rasterLayer(LAYER_NAMES.shadow, size, shadowRgba(shadow)));
  }
  layers.push(cutoutLayer(size, input));
  return layers;
};

const resolutionInfo = (density) => ({
  horizontalResolution: density,
  horizontalResolutionUnit: "PPI",
  widthUnit: "Inches",
  verticalResolution: density,
  verticalResolutionUnit: "PPI",
  heightUnit: "Inches",
});

// --- encode -----------------------------------------------------------------------

/**
 * Returns the bytes of a layered PSD. `color` is the full colour of the canvas
 * (not zeroed under transparency), `alpha` the cutout alone, `shadow` its
 * coverage with the opacity already applied, `original` the uploaded image
 * aligned to the canvas.
 */
export const encodePsd = ({
  width,
  height,
  color,
  alpha,
  original = null,
  shadow = null,
  background = null,
  density = null,
}) => {
  const input = {
    width,
    height,
    color,
    alpha,
    original: original ?? null,
    shadow: shadow ?? null,
    background: background ?? null,
    density: density ?? null,
  };
  assertInputs(input);

  const size = { width, height };
  const psd = {
    width,
    height,
    children: buildLayers(size, input),
    imageData: flatten(input),
  };
  if (input.density !== null) {
    psd.imageResources = { resolutionInfo: resolutionInfo(input.density) };
  }
  // noBackground: keep a bottom layer that happens to be opaque (the original,
  // the background colour) a normal, movable layer instead of Photoshop's
  // locked "Background".
  return writePsdBuffer(psd, { noBackground: true });
};
