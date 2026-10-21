// Local stand-in for remove.bg's server-side AI shadows. The subject silhouette
// is turned into a soft black coverage plane: "drop" is the silhouette offset to
// the lower right; the other types are a flattened ground contact shadow under
// the subject's base. Everything is clipped to the canvas.

import sharp from "sharp";

// libvips drops Gaussian taps below this fraction of the peak. Its default (0.2)
// cuts the tails at about 1.8 sigma, which makes a hard-edged, boxy shadow.
const BLUR_MIN_AMPLITUDE = 0.01;
// sharp rejects larger sigmas.
const MAX_SIGMA = 1000;

const contact = (squash, blur) =>
  Object.freeze({ kind: "contact", squash, blur, tuck: 0.01 });

/**
 * Per-type shadow geometry, all as fractions of the subject box:
 * - offset: `blur` is sigma / longer side; `offsetX`/`offsetY` are fractions of
 *   the box width/height.
 * - contact: `squash` is the shadow height / box height, `blur` is sigma / box
 *   width, and `tuck` is how far the shadow's centre sits above the box bottom
 *   (fraction of the box height).
 */
export const SHADOW_STYLES = Object.freeze({
  drop: Object.freeze({
    kind: "offset",
    blur: 0.015,
    offsetX: 0.02,
    offsetY: 0.03,
  }),
  car: contact(0.06, 0.02),
  "3D": contact(0.12, 0.04),
  auto: contact(0.08, 0.03),
});

const intersect = (a, b) => {
  const left = Math.max(a.left, b.left);
  const top = Math.max(a.top, b.top);
  const right = Math.min(a.left + a.width, b.left + b.width);
  const bottom = Math.min(a.top + a.height, b.top + b.height);
  if (right <= left || bottom <= top) return null;
  return { left, top, width: right - left, height: bottom - top };
};

const grow = (rect, by) => ({
  left: rect.left - by,
  top: rect.top - by,
  width: rect.width + 2 * by,
  height: rect.height + 2 * by,
});

// The kernel stops where the Gaussian falls under BLUR_MIN_AMPLITUDE.
const blurReach = (sigma) =>
  Math.ceil(sigma * Math.sqrt(-2 * Math.log(BLUR_MIN_AMPLITUDE))) + 1;

const sigmaFor = (fraction, length) =>
  Math.min(Math.max(1, fraction * length), MAX_SIGMA);

// sharp comes back with 3 channels for 1-channel raw data unless told "b-w".
const readPlane = async (pipeline, { width, height }) => {
  const data = await pipeline.toColourspace("b-w").raw().toBuffer();
  if (data.length !== width * height) {
    throw new Error(
      `Shadow plane has ${data.length} bytes; expected ${width * height}.`,
    );
  }
  return data;
};

const planeInput = (plane, { width, height }) =>
  sharp(plane, { raw: { width, height, channels: 1 } });

/** The subject's alpha inside `box`, row by row. */
const silhouette = (alpha, width, box) => {
  const plane = new Uint8Array(box.width * box.height);
  for (let y = 0; y < box.height; y++) {
    const from = (box.top + y) * width + box.left;
    plane.set(alpha.subarray(from, from + box.width), y * box.width);
  }
  return plane;
};

const offsetShape = (alpha, width, box, style) => ({
  plane: silhouette(alpha, width, box),
  rect: {
    left: box.left + Math.round(style.offsetX * box.width),
    top: box.top + Math.round(style.offsetY * box.height),
    width: box.width,
    height: box.height,
  },
  sigma: sigmaFor(style.blur, Math.max(box.width, box.height)),
});

const contactShape = async (alpha, width, box, style) => {
  const rows = Math.max(2, Math.round(style.squash * box.height));
  const rect = {
    left: box.left,
    // Centred just above the base so the shadow reads as touching the subject.
    top:
      box.top +
      box.height -
      Math.round(style.tuck * box.height) -
      Math.floor(rows / 2),
    width: box.width,
    height: rows,
  };
  // "linear" averages the columns without the overshoot of lanczos.
  const squashed = planeInput(silhouette(alpha, width, box), box).resize(
    box.width,
    rows,
    { fit: "fill", kernel: "linear" },
  );
  return {
    plane: await readPlane(squashed, rect),
    rect,
    sigma: sigmaFor(style.blur, box.width),
  };
};

const buildShape = (alpha, width, box, style) =>
  style.kind === "offset"
    ? offsetShape(alpha, width, box, style)
    : contactShape(alpha, width, box, style);

// Copies the part of `plane` (placed at `rect`) that falls inside `tile`.
const pasteInto = (layer, tile, plane, rect) => {
  const overlap = intersect(rect, tile);
  if (overlap === null) return;
  for (let y = overlap.top; y < overlap.top + overlap.height; y++) {
    const from = (y - rect.top) * rect.width + (overlap.left - rect.left);
    layer.set(
      plane.subarray(from, from + overlap.width),
      (y - tile.top) * tile.width + (overlap.left - tile.left),
    );
  }
};

// Maps the coverage through the opacity, in place.
const applyOpacity = (plane, opacity) => {
  const table = Uint8Array.from({ length: 256 }, (_, value) =>
    Math.round(value * opacity),
  );
  for (let i = 0; i < plane.length; i++) plane[i] = table[plane[i]];
};

const copyRows = (out, canvasWidth, tile, plane) => {
  for (let y = 0; y < tile.height; y++) {
    out.set(
      plane.subarray(y * tile.width, (y + 1) * tile.width),
      (tile.top + y) * canvasWidth + tile.left,
    );
  }
};

// Blurs a shape and lays it onto a blank canvas-sized plane. Only the area the
// blur can reach is processed, not the whole canvas.
const castShape = async ({ plane, rect, sigma }, canvas, opacity) => {
  const out = new Uint8Array(canvas.width * canvas.height);
  const tile = intersect(grow(rect, blurReach(sigma)), {
    left: 0,
    top: 0,
    ...canvas,
  });
  if (tile === null) return out;
  const layer = Buffer.alloc(tile.width * tile.height);
  pasteInto(layer, tile, plane, rect);
  const blurred = await readPlane(
    planeInput(layer, tile).blur({ sigma, minAmplitude: BLUR_MIN_AMPLITUDE }),
    tile,
  );
  applyOpacity(blurred, opacity);
  copyRows(out, canvas.width, tile, blurred);
  return out;
};

/**
 * Soft black shadow coverage for a subject on a `width` x `height` canvas.
 *
 * @param {object} args
 * @param {Uint8Array} args.alpha final canvas alpha, `width * height` values
 * @param {{left: number, top: number, width: number, height: number}} args.box
 *   the subject's bounding box on the canvas
 * @param {string} args.type "none", "auto", "car", "3D" or "drop"
 * @param {number} args.opacity 0..1, multiplied into the coverage
 * @returns {Promise<Uint8Array | null>} coverage 0..255 per pixel, or null when
 *   there is nothing to draw (type "none" or opacity 0)
 */
export const renderShadow = async ({
  alpha,
  width,
  height,
  box,
  type,
  opacity,
}) => {
  if (!(opacity >= 0 && opacity <= 1)) {
    throw new RangeError(`Shadow opacity must be 0 to 1, got ${opacity}.`);
  }
  if (type === "none" || opacity === 0) return null;
  if (!Object.hasOwn(SHADOW_STYLES, type)) {
    throw new Error(`Unknown shadow type ${JSON.stringify(type)}.`);
  }
  const shape = await buildShape(alpha, width, box, SHADOW_STYLES[type]);
  return castShape(shape, { width, height }, opacity);
};
