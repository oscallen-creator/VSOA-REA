// The one entry point the app and the CLI use: decode an image, find the
// subject with a local model, and compose the output with remove.bg-style
// options. The model is downloaded and verified on first use.

import sharp from "sharp";
import { compose } from "./compose.js";
import { defaultModelDir, ensureModel } from "./modelStore.js";
import { DEFAULT_MODEL_ID, getModel } from "./models.js";
import { parseOptions } from "./options.js";
import { createSegmenter } from "./segment.js";

/** Larger inputs are scaled down to this many pixels before processing. */
export const MAX_INPUT_PIXELS = 50_000_000;
/** Refuse to decode anything beyond this (decompression bombs). */
const DECODE_PIXEL_LIMIT = 1_000_000_000;
const WHITE = { r: 255, g: 255, b: 255 };

// EXIF orientations 5-8 turn the image a quarter, swapping its sides.
const uprightSize = ({ width, height, orientation }) =>
  orientation >= 5 ? { width: height, height: width } : { width, height };

/** The largest size with the same aspect that fits maxPixels, or null. */
export const fitArea = ({ width, height }, maxPixels) => {
  if (width * height <= maxPixels) return null;
  const ratio = Math.sqrt(maxPixels / (width * height));
  const fitted = {
    width: Math.max(1, Math.floor(width * ratio)),
    height: Math.max(1, Math.floor(height * ratio)),
  };
  // A side clamped up to 1 px can push a very thin image over the budget.
  if (fitted.width * fitted.height > maxPixels) {
    if (fitted.width > fitted.height) {
      fitted.width = Math.max(1, Math.floor(maxPixels / fitted.height));
    } else {
      fitted.height = Math.max(1, Math.floor(maxPixels / fitted.width));
    }
  }
  return fitted;
};

/**
 * Decodes any format sharp reads into 8-bit sRGB pixels, upright (EXIF
 * orientation applied) and flattened over white, plus the input's DPI.
 */
export const decodeImage = async (
  input,
  { maxPixels = MAX_INPUT_PIXELS } = {},
) => {
  const source = () => sharp(input, { limitInputPixels: DECODE_PIXEL_LIMIT });
  const metadata = await source().metadata();
  let pipeline = source()
    .rotate()
    .flatten({ background: WHITE })
    .toColourspace("srgb");
  const target = fitArea(uprightSize(metadata), maxPixels);
  if (target) {
    pipeline = pipeline.resize(target.width, target.height, {
      fit: "fill",
      kernel: "lanczos3",
    });
  }
  const { data, info } = await pipeline
    .removeAlpha()
    .raw({ depth: "uchar" })
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 3) {
    throw new Error(`Decoded ${info.channels} channels instead of RGB`);
  }
  return {
    image: { data, width: info.width, height: info.height, channels: 3 },
    density: metadata.density ?? null,
    format: metadata.format,
  };
};

/**
 * @param {object} [config]
 * @param {string} [config.modelId] key of MODELS
 * @param {string} [config.modelDir] where models are cached
 * @param {Function} [config.onModelProgress] download progress
 */
export const createRemover = ({
  modelId = DEFAULT_MODEL_ID,
  modelDir = defaultModelDir(),
  fetch,
  onModelProgress,
  createSegmenterFn = createSegmenter,
} = {}) => {
  const model = getModel(modelId);
  let segmenter;

  const prepare = ({ signal } = {}) => {
    if (segmenter) return segmenter;
    const attempt = ensureModel(model, {
      dir: modelDir,
      fetch,
      signal,
      onProgress: onModelProgress,
    })
      .then((file) => createSegmenterFn(file, model))
      .catch((error) => {
        // Let a later call retry, e.g. after the network comes back, unless a
        // newer attempt (after dispose) has already taken this one's place.
        if (segmenter === attempt) segmenter = undefined;
        throw error;
      });
    segmenter = attempt;
    return attempt;
  };

  const removeBackground = async (input, rawOptions = {}) => {
    const options = parseOptions(rawOptions);
    const decoded = await decodeImage(input);
    const { segment } = await prepare();
    const alpha = await segment(decoded.image);
    const result = await compose({
      image: decoded.image,
      alpha,
      options,
      density: decoded.density,
    });
    return {
      ...result,
      input: {
        width: decoded.image.width,
        height: decoded.image.height,
        density: decoded.density,
        format: decoded.format,
      },
    };
  };

  const dispose = async () => {
    const pending = segmenter;
    segmenter = undefined;
    if (pending) await (await pending.catch(() => null))?.dispose();
  };

  return { model, prepare, removeBackground, dispose };
};
