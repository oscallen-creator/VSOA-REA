// Shared fixtures and assertions for the compose tests. It has no tests of its
// own; it is named *.test.js so the test glob and the file allow-list cover it.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import sharp from "sharp";
import { compose } from "../src/engine/compose.js";

const exec = promisify(execFile);

export const W = 40;
export const H = 30;
// A 20x20 subject in the middle-left of the 40x30 test image.
export const SUBJECT = { x: 10, y: 5, w: 20, h: 20 };
export const FLAT = [200, 100, 50];

export const px = (value) => ({ value, unit: "px" });
export const pct = (value) => ({ value, unit: "%" });
export const sides = (margin) => ({
  top: margin,
  right: margin,
  bottom: margin,
  left: margin,
});

export const BASE_OPTIONS = Object.freeze({
  size: "auto",
  format: "auto",
  channels: "rgba",
  type: "auto",
  bgColor: null,
  bgImage: null,
  crop: false,
  cropMargin: sides(px(0)),
  scale: null,
  position: null,
  roi: null,
  shadowType: "none",
  shadowOpacity: 0,
});
export const opts = (overrides = {}) => ({ ...BASE_OPTIONS, ...overrides });

/** Colour depends on position so a misplaced pixel cannot go unnoticed. */
export const gradientImage = (width, height) => {
  const data = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 3;
      data[i] = (x * 6) % 256;
      data[i + 1] = (y * 8) % 256;
      data[i + 2] = 77;
    }
  }
  return { data, width, height, channels: 3 };
};

export const solidImage = (width, height, [r, g, b] = FLAT) => {
  const data = Buffer.alloc(width * height * 3);
  for (let i = 0; i < data.length; i += 3) {
    data[i] = r;
    data[i + 1] = g;
    data[i + 2] = b;
  }
  return { data, width, height, channels: 3 };
};

/** A mask with one filled rectangle, or several when given an array. */
export const rectMask = (width, height, rects, value = 255) => {
  const mask = new Uint8Array(width * height);
  for (const { x, y, w, h } of [rects].flat()) {
    for (let row = y; row < y + h; row++) {
      mask.fill(value, row * width + x, row * width + x + w);
    }
  }
  return mask;
};

export const imageRgb = (image, x, y) => {
  const i = (y * image.width + x) * 3;
  return [...image.data.subarray(i, i + 3)];
};

export const render = (
  overrides = {},
  {
    image = gradientImage(W, H),
    alpha = rectMask(W, H, SUBJECT),
    density,
  } = {},
) => compose({ image, alpha, options: opts(overrides), density });

/** Decodes to raw pixels; a grayscale PNG decodes as a single channel. */
export const decode = async (buffer) => {
  const { channels } = await sharp(buffer).metadata();
  const pipeline =
    channels === 1 ? sharp(buffer).toColourspace("b-w") : sharp(buffer);
  const { data, info } = await pipeline
    .raw()
    .toBuffer({ resolveWithObject: true });
  return {
    data,
    width: info.width,
    height: info.height,
    channels: info.channels,
  };
};

export const pixel = (img, x, y) => {
  const i = (y * img.width + x) * img.channels;
  return [...img.data.subarray(i, i + img.channels)];
};

/** A matte must be a real 1-channel grayscale PNG of exactly width x height. */
export const decodeMatte = async (buffer, width, height) => {
  const meta = await sharp(buffer).metadata();
  assert.equal(meta.format, "png");
  assert.equal(meta.channels, 1, "PNG metadata channels");
  assert.equal(meta.space, "b-w");
  const matte = await decode(buffer);
  assert.equal(matte.channels, 1, "decoded channels");
  assert.equal(matte.width, width);
  assert.equal(matte.height, height);
  assert.equal(matte.data.length, width * height);
  return matte;
};

export const rgb = (img, x, y) => pixel(img, x, y).slice(0, 3);

export const alphaPlane = (img) => {
  assert.equal(img.channels, 4);
  const plane = Buffer.alloc(img.width * img.height);
  for (let i = 0; i < plane.length; i++) plane[i] = img.data[i * 4 + 3];
  return plane;
};

/** Bounding box of pixels at least half opaque. */
export const opaqueBounds = (img, threshold = 128) => {
  const plane = alphaPlane(img);
  let left = img.width;
  let top = img.height;
  let right = -1;
  let bottom = -1;
  plane.forEach((value, i) => {
    if (value < threshold) return;
    const x = i % img.width;
    const y = Math.floor(i / img.width);
    left = Math.min(left, x);
    right = Math.max(right, x);
    top = Math.min(top, y);
    bottom = Math.max(bottom, y);
  });
  return { left, top, width: right - left + 1, height: bottom - top + 1 };
};

export const countAbove = (img, threshold) =>
  alphaPlane(img).filter((value) => value > threshold).length;

export const assertNear = (actual, expected, tolerance, label = "pixel") => {
  assert.equal(actual.length, expected.length, `${label}: channel count`);
  actual.forEach((value, i) => {
    assert.ok(
      Math.abs(value - expected[i]) <= tolerance,
      `${label}: channel ${i} is ${value}, expected ${expected[i]} +/- ${tolerance} (got [${actual}], want [${expected}])`,
    );
  });
};

// Hard edges on a tiny image ring through JPEG's 4:2:0 chroma blocks.
export const JPEG_TOLERANCE = 12;
export const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

/** Writes an archive to a temporary file for `unzip`, then removes it. */
const withZipFile = async (buffer, run) => {
  const dir = await mkdtemp(path.join(tmpdir(), "compose-zip-"));
  try {
    const file = path.join(dir, "out.zip");
    await writeFile(file, buffer);
    return await run(file);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
};

/** The archive's files by name, in archive order, extracted with `unzip`. */
export const unzipEntries = (buffer) =>
  withZipFile(buffer, async (file) => {
    const { stdout } = await exec("unzip", ["-Z1", file]);
    const entries = {};
    for (const name of stdout.trim().split("\n")) {
      const extracted = await exec("unzip", ["-p", file, name], {
        encoding: "buffer",
        maxBuffer: 1 << 24,
      });
      entries[name] = extracted.stdout;
    }
    return entries;
  });

/** The output of `unzip -t`, which checks every entry's integrity. */
export const testZip = (buffer) =>
  withZipFile(
    buffer,
    async (file) => (await exec("unzip", ["-t", file])).stdout,
  );
