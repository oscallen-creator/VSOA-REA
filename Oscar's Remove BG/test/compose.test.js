import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import sharp from "sharp";
import {
  ForegroundError,
  SUBJECT_ALPHA_THRESHOLD,
  applyRoi,
  compose,
  findSubjectBox,
  fitToMaxPixels,
} from "../src/engine/compose.js";

const exec = promisify(execFile);

const W = 40;
const H = 30;
// A 20x20 subject in the middle-left of the 40x30 test image.
const SUBJECT = { x: 10, y: 5, w: 20, h: 20 };
const FLAT = [200, 100, 50];

const px = (value) => ({ value, unit: "px" });
const pct = (value) => ({ value, unit: "%" });
const sides = (margin) => ({
  top: margin,
  right: margin,
  bottom: margin,
  left: margin,
});

const BASE_OPTIONS = Object.freeze({
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
});
const opts = (overrides = {}) => ({ ...BASE_OPTIONS, ...overrides });

/** Colour depends on position so a misplaced pixel cannot go unnoticed. */
const gradientImage = (width, height) => {
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

const solidImage = (width, height, [r, g, b] = FLAT) => {
  const data = Buffer.alloc(width * height * 3);
  for (let i = 0; i < data.length; i += 3) {
    data[i] = r;
    data[i + 1] = g;
    data[i + 2] = b;
  }
  return { data, width, height, channels: 3 };
};

/** A mask with one filled rectangle, or several when given an array. */
const rectMask = (width, height, rects, value = 255) => {
  const mask = new Uint8Array(width * height);
  for (const { x, y, w, h } of [rects].flat()) {
    for (let row = y; row < y + h; row++) {
      mask.fill(value, row * width + x, row * width + x + w);
    }
  }
  return mask;
};

const imageRgb = (image, x, y) => {
  const i = (y * image.width + x) * 3;
  return [...image.data.subarray(i, i + 3)];
};

const render = (
  overrides = {},
  { image = gradientImage(W, H), alpha = rectMask(W, H, SUBJECT) } = {},
) => compose({ image, alpha, options: opts(overrides) });

/** Decodes to raw pixels; a grayscale PNG decodes as a single channel. */
const decode = async (buffer) => {
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

const pixel = (img, x, y) => {
  const i = (y * img.width + x) * img.channels;
  return [...img.data.subarray(i, i + img.channels)];
};

/** A matte must be a real 1-channel grayscale PNG of exactly width x height. */
const decodeMatte = async (buffer, width, height) => {
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

const rgb = (img, x, y) => pixel(img, x, y).slice(0, 3);

const alphaPlane = (img) => {
  assert.equal(img.channels, 4);
  const plane = Buffer.alloc(img.width * img.height);
  for (let i = 0; i < plane.length; i++) plane[i] = img.data[i * 4 + 3];
  return plane;
};

/** Bounding box of pixels at least half opaque. */
const opaqueBounds = (img, threshold = 128) => {
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

const countAbove = (img, threshold) =>
  alphaPlane(img).filter((value) => value > threshold).length;

const assertNear = (actual, expected, tolerance, label = "pixel") => {
  assert.equal(actual.length, expected.length, `${label}: channel count`);
  actual.forEach((value, i) => {
    assert.ok(
      Math.abs(value - expected[i]) <= tolerance,
      `${label}: channel ${i} is ${value}, expected ${expected[i]} +/- ${tolerance} (got [${actual}], want [${expected}])`,
    );
  });
};

// Hard edges on a tiny image ring through JPEG's 4:2:0 chroma blocks.
const JPEG_TOLERANCE = 12;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

describe("default output", () => {
  test("keeps transparency as an RGBA PNG with the mask as alpha", async () => {
    const image = gradientImage(W, H);
    const alpha = rectMask(W, H, SUBJECT);
    alpha[12 * W + 15] = 128; // soft pixel inside the subject
    alpha[1 * W + 1] = 5; // below the subject threshold, outside the box
    const result = await compose({ image, alpha, options: opts() });

    assert.equal(result.format, "png");
    assert.equal(result.mime, "image/png");
    assert.deepEqual(result.buffer.subarray(0, 4), PNG_SIGNATURE);
    assert.equal(result.width, W);
    assert.equal(result.height, H);

    const out = await decode(result.buffer);
    assert.equal(out.channels, 4);
    assert.deepEqual(alphaPlane(out), Buffer.from(alpha));
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (alpha[y * W + x] === 0) continue;
        assert.deepEqual(pixel(out, x, y).slice(0, 3), imageRgb(image, x, y));
      }
    }
  });

  test("leaves the caller's pixels and mask untouched", async () => {
    const image = gradientImage(W, H);
    const alpha = rectMask(W, H, SUBJECT);
    const pixelsBefore = Buffer.from(image.data);
    const alphaBefore = Uint8Array.from(alpha);
    await compose({
      image,
      alpha,
      options: opts({
        roi: [px(12), px(6), px(28), px(20)],
        bgColor: { r: 1, g: 2, b: 3, alpha: 1 },
      }),
    });
    assert.deepEqual(image.data, pixelsBefore);
    assert.deepEqual(alpha, alphaBefore);
  });

  test("reports the subject box in original pixels", async () => {
    const result = await render();
    assert.deepEqual(result.subjectBox, {
      left: SUBJECT.x,
      top: SUBJECT.y,
      width: SUBJECT.w,
      height: SUBJECT.h,
    });
  });

  test("picks JPEG under auto when nothing is transparent", async () => {
    const result = await render({}, { alpha: new Uint8Array(W * H).fill(255) });
    assert.equal(result.format, "jpg");
    assert.equal(result.mime, "image/jpeg");
    assert.equal((await decode(result.buffer)).channels, 3);
  });
});

describe("subject box", () => {
  test("uses the alpha threshold as an inclusive lower bound", () => {
    assert.equal(SUBJECT_ALPHA_THRESHOLD, 10);
    const alpha = new Uint8Array(W * H);
    alpha[7 * W + 9] = SUBJECT_ALPHA_THRESHOLD - 1;
    assert.throws(() => findSubjectBox(alpha, W, H), ForegroundError);
    alpha[7 * W + 9] = SUBJECT_ALPHA_THRESHOLD;
    assert.deepEqual(findSubjectBox(alpha, W, H), {
      left: 9,
      top: 7,
      width: 1,
      height: 1,
    });
  });

  test("spans every separate blob", () => {
    const alpha = rectMask(W, H, [
      { x: 2, y: 3, w: 4, h: 2 },
      { x: 30, y: 20, w: 5, h: 8 },
    ]);
    assert.deepEqual(findSubjectBox(alpha, W, H), {
      left: 2,
      top: 3,
      width: 33,
      height: 25,
    });
  });

  test("throws ForegroundError when nothing reaches the threshold", async () => {
    await assert.rejects(
      render({}, { alpha: new Uint8Array(W * H) }),
      (error) => {
        assert.ok(error instanceof ForegroundError);
        assert.ok(error instanceof Error);
        assert.equal(error.code, "unknown_foreground");
        assert.equal(error.message, "Could not identify foreground in image.");
        return true;
      },
    );
  });
});

describe("region of interest", () => {
  test("zeroes the mask outside the ROI and reports the surviving box", async () => {
    const alpha = new Uint8Array(W * H).fill(255);
    const before = Uint8Array.from(alpha);
    const result = await render(
      { channels: "alpha", roi: [px(5), px(4), px(25), px(20)] },
      { alpha },
    );
    const out = await decode(result.buffer);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const inside = x >= 5 && x < 25 && y >= 4 && y < 20;
        assert.equal(out.data[y * W + x], inside ? 255 : 0, `(${x},${y})`);
      }
    }
    assert.deepEqual(alpha, before, "caller's mask must not change");
    assert.deepEqual(result.subjectBox, {
      left: 5,
      top: 4,
      width: 20,
      height: 16,
    });
  });

  test("applyRoi converts percentages against the matching axis", () => {
    const alpha = new Uint8Array(W * H).fill(255);
    const masked = applyRoi(alpha, [pct(25), pct(10), pct(75), pct(90)], W, H);
    assert.notEqual(masked, alpha);
    assert.deepEqual(findSubjectBox(masked, W, H), {
      left: 10, // 25% of 40
      top: 3, // 10% of 30
      width: 20, // up to 75% of 40 = 30
      height: 24, // up to 90% of 30 = 27
    });
    assert.ok(alpha.every((value) => value === 255));
  });

  test("applyRoi clamps to the image and treats an inverted box as empty", () => {
    const alpha = new Uint8Array(W * H).fill(255);
    const clamped = applyRoi(alpha, [px(-5), px(-5), px(500), px(500)], W, H);
    assert.deepEqual(clamped, alpha);
    const inverted = applyRoi(alpha, [px(20), px(20), px(10), px(10)], W, H);
    assert.ok(inverted.every((value) => value === 0));
  });

  test("applyRoi passes the mask through when there is no ROI", () => {
    const alpha = rectMask(W, H, SUBJECT);
    assert.deepEqual(applyRoi(alpha, null, W, H), alpha);
  });

  test("throws ForegroundError when the mask lies fully outside the ROI", async () => {
    await assert.rejects(
      render({ roi: [px(0), px(0), px(8), px(4)] }),
      ForegroundError,
    );
  });

  test("throws ForegroundError for an empty ROI", async () => {
    await assert.rejects(
      render({ roi: [px(20), px(10), px(20), px(25)] }),
      ForegroundError,
    );
  });

  test("keeps only the blob inside the ROI in the reported box", async () => {
    const alpha = rectMask(W, H, [
      { x: 2, y: 2, w: 4, h: 4 },
      { x: 30, y: 20, w: 6, h: 6 },
    ]);
    const result = await render(
      { roi: [px(25), px(15), px(40), px(30)] },
      { alpha },
    );
    assert.deepEqual(result.subjectBox, {
      left: 30,
      top: 20,
      width: 6,
      height: 6,
    });
  });
});

describe("crop", () => {
  test("with zero margin is exactly the subject box", async () => {
    const image = gradientImage(W, H);
    // A fully opaque crop would be a JPEG under auto; PNG keeps pixels exact.
    const result = await render({ crop: true, format: "png" }, { image });
    assert.equal(result.width, SUBJECT.w);
    assert.equal(result.height, SUBJECT.h);
    const out = await decode(result.buffer);
    assert.equal(out.width, SUBJECT.w);
    assert.equal(out.height, SUBJECT.h);
    assert.deepEqual(pixel(out, 0, 0), [
      ...imageRgb(image, SUBJECT.x, SUBJECT.y),
      255,
    ]);
    assert.deepEqual(pixel(out, 19, 19), [
      ...imageRgb(image, SUBJECT.x + 19, SUBJECT.y + 19),
      255,
    ]);
  });

  test("adds pixel margins on every side", async () => {
    const result = await render({ crop: true, cropMargin: sides(px(3)) });
    assert.equal(result.width, SUBJECT.w + 6);
    assert.equal(result.height, SUBJECT.h + 6);
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 3,
      top: 3,
      width: 20,
      height: 20,
    });
  });

  test("applies four different margins to the right sides", async () => {
    const result = await render({
      crop: true,
      cropMargin: { top: px(2), right: px(4), bottom: px(6), left: px(8) },
    });
    assert.equal(result.width, 8 + SUBJECT.w + 4);
    assert.equal(result.height, 2 + SUBJECT.h + 6);
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 8,
      top: 2,
      width: 20,
      height: 20,
    });
  });

  test("measures percent margins against the matching subject dimension", async () => {
    // Subject 20 wide, 10 tall: top/bottom use the height, left/right the width.
    const rect = { x: 10, y: 5, w: 20, h: 10 };
    const result = await render(
      {
        crop: true,
        cropMargin: {
          top: pct(40),
          right: pct(25),
          bottom: pct(10),
          left: pct(50),
        },
      },
      { alpha: rectMask(W, H, rect) },
    );
    // top 40% of 10 = 4, right 25% of 20 = 5, bottom 10% of 10 = 1, left 50% of 20 = 10
    assert.equal(result.width, 10 + 20 + 5);
    assert.equal(result.height, 4 + 10 + 1);
  });
});

describe("crop margin limits", () => {
  test("caps each margin at half of that subject dimension", async () => {
    const rect = { x: 10, y: 5, w: 20, h: 10 };
    const result = await render(
      { crop: true, cropMargin: sides(px(1000)) },
      { alpha: rectMask(W, H, rect) },
    );
    assert.equal(result.width, 20 + 10 + 10);
    assert.equal(result.height, 10 + 5 + 5);

    const percent = await render(
      { crop: true, cropMargin: sides(pct(300)) },
      { alpha: rectMask(W, H, rect) },
    );
    assert.equal(percent.width, 40);
    assert.equal(percent.height, 20);
  });

  test("caps each margin at 500 px on large subjects", async () => {
    const wide = { x: 0, y: 40, w: 1200, h: 20 };
    const result = await render(
      {
        crop: true,
        cropMargin: {
          top: px(0),
          right: pct(100),
          bottom: px(0),
          left: px(900),
        },
      },
      { image: solidImage(1200, 100), alpha: rectMask(1200, 100, wide) },
    );
    assert.equal(result.width, 500 + 1200 + 500);
    assert.equal(result.height, 20);
  });

  test("rounds fractional margins", async () => {
    const rect = { x: 10, y: 5, w: 25, h: 10 };
    const result = await render(
      {
        crop: true,
        cropMargin: { top: px(0), right: pct(10), bottom: px(0), left: px(0) },
      },
      { alpha: rectMask(W, H, rect) },
    );
    assert.equal(result.width, 25 + Math.round(2.5));
  });
});

describe("crop placement", () => {
  test("keeps real pixels in margins that fall inside the image", async () => {
    const image = gradientImage(W, H);
    const result = await render(
      { crop: true, cropMargin: sides(px(3)) },
      { image },
    );
    const out = await decode(result.buffer);
    // Output (0,0) is source (7,2): masked out (alpha 0) but its colour is kept.
    assert.deepEqual(pixel(out, 0, 0), [...imageRgb(image, 7, 2), 0]);
    assert.deepEqual(pixel(out, 3, 3), [
      ...imageRgb(image, SUBJECT.x, SUBJECT.y),
      255,
    ]);
  });

  test("pads transparently where margins pass the top-left image edges", async () => {
    const image = gradientImage(W, H);
    const corner = { x: 0, y: 0, w: 10, h: 10 };
    const result = await render(
      { crop: true, cropMargin: sides(px(4)) },
      { image, alpha: rectMask(W, H, corner) },
    );
    assert.equal(result.width, 18);
    assert.equal(result.height, 18);
    const out = await decode(result.buffer);
    for (let i = 0; i < 18; i++) {
      assert.deepEqual(pixel(out, i, 0), [0, 0, 0, 0], `top row ${i}`);
      assert.deepEqual(pixel(out, 0, i), [0, 0, 0, 0], `left column ${i}`);
    }
    assert.deepEqual(pixel(out, 4, 4), [...imageRgb(image, 0, 0), 255]);
    assert.deepEqual(opaqueBounds(out), {
      left: 4,
      top: 4,
      width: 10,
      height: 10,
    });
    // Margin on the far sides is still inside the image, so it is real pixels.
    assert.deepEqual(pixel(out, 17, 17).slice(0, 3), imageRgb(image, 13, 13));
  });

  test("pads transparently where margins pass the bottom-right image edges", async () => {
    const image = gradientImage(W, H);
    const corner = { x: 30, y: 20, w: 10, h: 10 };
    const result = await render(
      { crop: true, cropMargin: sides(px(4)) },
      { image, alpha: rectMask(W, H, corner) },
    );
    assert.equal(result.width, 18);
    assert.equal(result.height, 18);
    const out = await decode(result.buffer);
    for (let i = 0; i < 18; i++) {
      assert.deepEqual(pixel(out, i, 17), [0, 0, 0, 0], `bottom row ${i}`);
      assert.deepEqual(pixel(out, 17, i), [0, 0, 0, 0], `right column ${i}`);
    }
    assert.deepEqual(opaqueBounds(out), {
      left: 4,
      top: 4,
      width: 10,
      height: 10,
    });
    assert.deepEqual(pixel(out, 0, 0).slice(0, 3), imageRgb(image, 26, 16));
  });

  test("ignores scale and position", async () => {
    const plain = await render({ crop: true, cropMargin: sides(px(2)) });
    const extras = await render({
      crop: true,
      cropMargin: sides(px(2)),
      scale: 0.5,
      position: { x: 1, y: 0 },
    });
    assert.equal(extras.width, plain.width);
    assert.equal(extras.height, plain.height);
    assert.deepEqual(
      (await decode(extras.buffer)).data,
      (await decode(plain.buffer)).data,
    );
  });

  test("keeps the subject box in original image coordinates", async () => {
    const result = await render({ crop: true, cropMargin: sides(px(3)) });
    assert.deepEqual(result.subjectBox, {
      left: SUBJECT.x,
      top: SUBJECT.y,
      width: SUBJECT.w,
      height: SUBJECT.h,
    });
  });
});

describe("scale and position", () => {
  const flat = () => solidImage(W, H);

  test("scale 0.5 centres the shrunken subject on the original canvas", async () => {
    const result = await render(
      { scale: 0.5, position: { x: 0.5, y: 0.5 } },
      { image: flat() },
    );
    assert.equal(result.width, W);
    assert.equal(result.height, H);
    const out = await decode(result.buffer);
    // factor = 0.5 * min(40/20, 30/20) = 0.75 -> 15x15, at (round(12.5), round(7.5)).
    assert.deepEqual(opaqueBounds(out), {
      left: 13,
      top: 8,
      width: 15,
      height: 15,
    });
    assert.equal(countAbove(out, 0), 15 * 15);
    assertNear(pixel(out, 20, 15), [...FLAT, 255], 2, "block centre");
    assertNear(pixel(out, 5, 5), [0, 0, 0, 0], 0, "outside");
  });

  test("scale without a position defaults to the centre", async () => {
    const result = await render({ scale: 0.5 }, { image: flat() });
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 13,
      top: 8,
      width: 15,
      height: 15,
    });
  });

  test("scale 1 grows the subject until it fills the canvas along one axis", async () => {
    const result = await render(
      { scale: 1, position: { x: 0.5, y: 0.5 } },
      { image: flat() },
    );
    const out = await decode(result.buffer);
    // factor = min(40/20, 30/20) = 1.5 -> 30x30, left = round(0.5 * 10).
    assert.deepEqual(opaqueBounds(out), {
      left: 5,
      top: 0,
      width: 30,
      height: 30,
    });
  });

  test("places a scaled subject by position", async () => {
    const result = await render(
      { scale: 0.5, position: { x: 1, y: 0 } },
      { image: flat() },
    );
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 25,
      top: 0,
      width: 15,
      height: 15,
    });
  });
});

describe("position", () => {
  test("position 0%/0% puts the unscaled subject in the top-left corner", async () => {
    const image = gradientImage(W, H);
    const result = await render({ position: { x: 0, y: 0 } }, { image });
    assert.equal(result.width, W);
    assert.equal(result.height, H);
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 0,
      top: 0,
      width: 20,
      height: 20,
    });
    assert.deepEqual(pixel(out, 0, 0), [...imageRgb(image, 10, 5), 255]);
    assert.deepEqual(pixel(out, 19, 19), [...imageRgb(image, 29, 24), 255]);
  });

  test("position 100%/100% puts the unscaled subject in the bottom-right corner", async () => {
    const image = gradientImage(W, H);
    const result = await render({ position: { x: 1, y: 1 } }, { image });
    const out = await decode(result.buffer);
    assert.deepEqual(opaqueBounds(out), {
      left: 20,
      top: 10,
      width: 20,
      height: 20,
    });
    assert.deepEqual(pixel(out, 20, 10), [...imageRgb(image, 10, 5), 255]);
    assert.deepEqual(pixel(out, 39, 29), [...imageRgb(image, 29, 24), 255]);
  });

  test("moves only the subject box, not faint pixels outside it", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[1 * W + 1] = SUBJECT_ALPHA_THRESHOLD - 1; // outside the box
    const result = await render({ position: { x: 1, y: 1 } }, { alpha });
    const out = await decode(result.buffer);
    assert.equal(countAbove(out, 0), SUBJECT.w * SUBJECT.h);
  });

  test("still reports the subject box in original coordinates", async () => {
    const result = await render({ scale: 0.5, position: { x: 1, y: 1 } });
    assert.deepEqual(result.subjectBox, {
      left: SUBJECT.x,
      top: SUBJECT.y,
      width: SUBJECT.w,
      height: SUBJECT.h,
    });
  });
});

describe("size", () => {
  test("fitToMaxPixels floors dimensions and leaves small sizes alone", () => {
    assert.deepEqual(fitToMaxPixels({ width: 400, height: 300 }, 250_000), {
      width: 400,
      height: 300,
    });
    const fitted = fitToMaxPixels({ width: 4000, height: 3000 }, 250_000);
    assert.deepEqual(fitted, { width: 577, height: 433 });
    assert.ok(fitted.width * fitted.height <= 250_000);
  });

  test("preview downscales a 1000x1000 image to at most 250000 pixels", async () => {
    const rect = { x: 100, y: 100, w: 800, h: 800 };
    const result = await render(
      { size: "preview" },
      { image: solidImage(1000, 1000), alpha: rectMask(1000, 1000, rect) },
    );
    assert.ok(result.width * result.height <= 250_000);
    assert.equal(result.width, 500);
    assert.equal(result.height, 500);
    const out = await decode(result.buffer);
    assert.equal(out.width, 500);
    assertNear(pixel(out, 250, 250), [...FLAT, 255], 2, "centre");
    assertNear(pixel(out, 5, 5), [0, 0, 0, 0], 2, "corner");
    // The reported box stays in original pixels.
    assert.deepEqual(result.subjectBox, {
      left: 100,
      top: 100,
      width: 800,
      height: 800,
    });
  });

  test("preview keeps the aspect ratio", async () => {
    const rect = { x: 200, y: 100, w: 800, h: 600 };
    const result = await render(
      { size: "preview" },
      { image: solidImage(1200, 800), alpha: rectMask(1200, 800, rect) },
    );
    assert.ok(result.width * result.height <= 250_000);
    assert.ok(Math.abs(result.width / result.height - 1.5) < 0.01);
    assert.ok(result.width * result.height > 240_000, "should use the budget");
  });

  test("full and auto do not downscale below the cap", async () => {
    const args = {
      image: solidImage(1000, 1000),
      alpha: rectMask(1000, 1000, { x: 100, y: 100, w: 800, h: 800 }),
    };
    for (const size of ["full", "auto"]) {
      const result = await render({ size }, args);
      assert.equal(result.width, 1000, size);
      assert.equal(result.height, 1000, size);
    }
  });

  test("scales crop margins together with the subject", async () => {
    const rect = { x: 100, y: 100, w: 800, h: 800 };
    const result = await render(
      { size: "preview", crop: true, cropMargin: sides(pct(10)) },
      { image: solidImage(1000, 1000), alpha: rectMask(1000, 1000, rect) },
    );
    // Canvas 960x960 -> about 500x500.
    assert.ok(result.width * result.height <= 250_000);
    assert.ok(
      result.width >= 499 && result.width <= 500,
      `width ${result.width}`,
    );
    assert.equal(result.width, result.height);
    const out = await decode(result.buffer);
    assertNear(pixel(out, 2, 2), [0, 0, 0, 0], 2, "margin corner");
    const middle = Math.floor(out.height / 2);
    let opaque = 0;
    for (let x = 0; x < out.width; x++)
      if (pixel(out, x, middle)[3] >= 128) opaque++;
    // 800 source pixels * (500 / 960) is about 417.
    assert.ok(Math.abs(opaque - 417) <= 2, `opaque run ${opaque}`);
  });
});

describe("background colour", () => {
  const green = { r: 10, g: 200, b: 30, alpha: 1 };

  test("an opaque colour makes the output a JPEG under auto", async () => {
    const result = await render(
      { bgColor: green },
      { image: solidImage(W, H) },
    );
    assert.equal(result.format, "jpg");
    assert.equal(result.mime, "image/jpeg");
    const out = await decode(result.buffer);
    assert.equal(out.channels, 3);
    assertNear(pixel(out, 2, 2), [10, 200, 30], JPEG_TOLERANCE, "background");
    assertNear(pixel(out, 20, 15), FLAT, JPEG_TOLERANCE, "subject");
  });

  test("puts the exact colour behind the subject and keeps it opaque", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 128;
    const result = await render(
      { bgColor: green, format: "png" },
      { image: solidImage(W, H), alpha },
    );
    const out = await decode(result.buffer);
    assert.ok(alphaPlane(out).every((value) => value === 255));
    assert.deepEqual(pixel(out, 2, 2), [10, 200, 30, 255]);
    assert.deepEqual(pixel(out, 20, 15), [...FLAT, 255]);
    // 128/255 of the subject over the colour.
    const mix = (subject, backdrop) => (subject * 128 + backdrop * 127) / 255;
    assertNear(
      pixel(out, 12, 10),
      [mix(200, 10), mix(100, 200), mix(50, 30), 255],
      1,
      "soft edge",
    );
  });

  test("a translucent colour yields alpha a_s + a_c * (1 - a_s)", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 128;
    const result = await render(
      { bgColor: { ...green, alpha: 0.5 } },
      { image: solidImage(W, H), alpha },
    );
    assert.equal(result.format, "png");
    const out = await decode(result.buffer);
    assertNear(pixel(out, 2, 2), [10, 200, 30, 128], 1, "background");
    assertNear(pixel(out, 20, 15), [...FLAT, 255], 0, "subject");
    const subjectAlpha = 128 / 255;
    const expected = Math.round(
      (subjectAlpha + 0.5 * (1 - subjectAlpha)) * 255,
    );
    assert.ok(Math.abs(pixel(out, 12, 10)[3] - expected) <= 1);
  });

  test("a fully transparent colour leaves a transparent background", async () => {
    const result = await render(
      { bgColor: { ...green, alpha: 0 } },
      { image: solidImage(W, H) },
    );
    assert.equal(result.format, "png");
    const out = await decode(result.buffer);
    assert.equal(pixel(out, 2, 2)[3], 0);
    assert.equal(pixel(out, 20, 15)[3], 255);
  });
});

const rawPng = (width, height, colorAt) => {
  const data = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++)
      data.set(colorAt(x, y), (y * width + x) * 3);
  }
  return sharp(data, { raw: { width, height, channels: 3 } })
    .png()
    .toBuffer();
};
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const GREEN = [0, 255, 0];

describe("background image", () => {
  test("covers the canvas, centred, with pixels from the image", async () => {
    // 80x20: the left quarter is red, the bottom quarter green, the rest blue.
    const bgImage = await rawPng(80, 20, (x, y) =>
      y >= 15 ? GREEN : x < 20 ? RED : BLUE,
    );
    const image = solidImage(W, H);
    const result = await render({ bgImage, format: "png" }, { image });
    const out = await decode(result.buffer);
    assert.equal(out.width, W);
    assert.equal(out.height, H);
    assert.ok(alphaPlane(out).every((value) => value === 255));
    // Cover scales by 1.5 to 120x30 and crops 40 columns from the middle, so
    // the red quarter is cropped away entirely (a stretch would show it).
    assertNear(rgb(out, 2, 2), BLUE, 2, "top left");
    assertNear(rgb(out, 37, 2), BLUE, 2, "top right");
    assertNear(rgb(out, 20, 28), GREEN, 2, "bottom");
    assertNear(rgb(out, 20, 15), FLAT, 0, "subject");
  });

  test("applies EXIF orientation to the background image", async () => {
    // 40x10 stored left red / right blue, tagged "rotate 90 degrees clockwise":
    // upright it is 10x40 with red on top and blue below.
    const stored = await sharp(
      await rawPng(40, 10, (x) => (x < 20 ? RED : BLUE)),
    )
      .jpeg({ quality: 95 })
      .withMetadata({ orientation: 6 })
      .toBuffer();
    const image = solidImage(20, 40);
    const alpha = rectMask(20, 40, { x: 5, y: 15, w: 10, h: 10 });
    const result = await render(
      { bgImage: stored, format: "png" },
      { image, alpha },
    );
    const out = await decode(result.buffer);
    assertNear(rgb(out, 17, 2), RED, 12, "top");
    assertNear(rgb(out, 2, 37), BLUE, 12, "bottom");
  });

  test("accepts a one-channel grayscale background image", async () => {
    const gray = await sharp(Buffer.alloc(8 * 8, 90), {
      raw: { width: 8, height: 8, channels: 1 },
    })
      .toColourspace("b-w")
      .png()
      .toBuffer();
    assert.equal((await sharp(gray).metadata()).channels, 1);
    const result = await render(
      { bgImage: gray, format: "png" },
      { image: solidImage(W, H) },
    );
    const out = await decode(result.buffer);
    assert.equal(out.channels, 4);
    assertNear(pixel(out, 2, 2), [90, 90, 90, 255], 1, "background");
  });
});

describe("background image edge cases", () => {
  test("flattens a transparent background image over white", async () => {
    const bgImage = await sharp({
      create: {
        width: 4,
        height: 4,
        channels: 4,
        background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    })
      .png()
      .toBuffer();
    const result = await render(
      { bgImage, format: "png" },
      { image: solidImage(W, H) },
    );
    const out = await decode(result.buffer);
    assert.deepEqual(pixel(out, 2, 2), [255, 255, 255, 255]);
  });

  test("blends soft mask edges with the image behind them", async () => {
    const bgImage = await rawPng(8, 8, () => BLUE);
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 128;
    const result = await render(
      { bgImage, format: "png" },
      { image: solidImage(W, H), alpha },
    );
    const out = await decode(result.buffer);
    const mix = (subject, backdrop) => (subject * 128 + backdrop * 127) / 255;
    assertNear(
      pixel(out, 12, 10),
      [mix(200, 0), mix(100, 0), mix(50, 255), 255],
      2,
    );
  });

  test("reports an unreadable background image", async () => {
    await assert.rejects(
      render({ bgImage: Buffer.from("definitely not an image") }),
      /background image/i,
    );
  });
});

describe("alpha channel output", () => {
  test("writes a one-channel grayscale PNG equal to the mask", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 77;
    alpha[3 * W + 3] = 4; // faint pixels are kept in the matte
    const result = await render({ channels: "alpha" }, { alpha });
    assert.equal(result.format, "png");
    assert.equal(result.mime, "image/png");
    assert.equal(result.width, W);
    assert.equal(result.height, H);
    const out = await decodeMatte(result.buffer, W, H);
    assert.deepEqual(out.data, Buffer.from(alpha));
  });

  test("ignores the background and the requested format", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    for (const format of ["auto", "png", "jpg", "webp"]) {
      const result = await render(
        { channels: "alpha", format, bgColor: { r: 9, g: 9, b: 9, alpha: 1 } },
        { alpha },
      );
      assert.equal(result.format, "png", format);
      const matte = await decodeMatte(result.buffer, W, H);
      assert.deepEqual(matte.data, Buffer.from(alpha), format);
    }
  });

  test("follows crop geometry", async () => {
    const result = await render({
      channels: "alpha",
      crop: true,
      cropMargin: sides(px(2)),
    });
    assert.equal(result.width, SUBJECT.w + 4);
    const out = await decodeMatte(result.buffer, SUBJECT.w + 4, SUBJECT.h + 4);
    assert.equal(out.data[0], 0);
    assert.equal(out.data[2 * out.width + 2], 255);
  });

  test("stays one channel when the canvas is downscaled", async () => {
    const rect = { x: 100, y: 100, w: 800, h: 800 };
    const result = await render(
      { channels: "alpha", size: "preview" },
      { image: solidImage(1000, 1000), alpha: rectMask(1000, 1000, rect) },
    );
    assert.equal(result.width, 500);
    const matte = await decodeMatte(result.buffer, 500, 500);
    assert.ok(Math.abs(matte.data[250 * 500 + 250] - 255) <= 2);
    assert.ok(matte.data[5 * 500 + 5] <= 2);
  });

  test("stays one channel when the subject is scaled and moved", async () => {
    const result = await render({
      channels: "alpha",
      scale: 0.5,
      position: { x: 0.5, y: 0.5 },
    });
    const matte = await decodeMatte(result.buffer, W, H);
    assert.equal(matte.data.filter((value) => value > 0).length, 15 * 15);
  });

  test("cannot be combined with zip", async () => {
    await assert.rejects(
      render({ channels: "alpha", format: "zip" }),
      (error) => {
        assert.ok(error instanceof Error);
        assert.ok(!(error instanceof ForegroundError));
        assert.match(error.message, /zip/);
        return true;
      },
    );
  });
});

describe("formats", () => {
  test("jpg flattens transparency over white", async () => {
    const result = await render({ format: "jpg" }, { image: solidImage(W, H) });
    assert.equal(result.format, "jpg");
    assert.equal(result.mime, "image/jpeg");
    const out = await decode(result.buffer);
    assert.equal(out.channels, 3);
    assert.equal(out.width, W);
    assertNear(pixel(out, 2, 2), [255, 255, 255], JPEG_TOLERANCE, "background");
    assertNear(pixel(out, 20, 15), FLAT, JPEG_TOLERANCE, "subject");
  });

  test("webp keeps alpha", async () => {
    const result = await render(
      { format: "webp" },
      { image: solidImage(W, H) },
    );
    assert.equal(result.format, "webp");
    assert.equal(result.mime, "image/webp");
    const meta = await sharp(result.buffer).metadata();
    assert.equal(meta.format, "webp");
    assert.equal(meta.hasAlpha, true);
    const out = await decode(result.buffer);
    assert.equal(out.channels, 4);
    assert.equal(pixel(out, 2, 2)[3], 0);
    assert.equal(pixel(out, 20, 15)[3], 255);
  });

  test("png stays RGBA even when fully opaque", async () => {
    const result = await render(
      { format: "png" },
      { alpha: new Uint8Array(W * H).fill(255) },
    );
    assert.equal(result.format, "png");
    assert.equal((await decode(result.buffer)).channels, 4);
  });
});

describe("zip output", () => {
  let dir;
  before(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "compose-zip-"));
  });
  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  const saveZip = async (name, buffer) => {
    const file = path.join(dir, name);
    await writeFile(file, buffer);
    return file;
  };
  const listEntries = async (file) =>
    (await exec("unzip", ["-Z1", file])).stdout.trim().split("\n");
  const extractEntry = async (file, name) =>
    (
      await exec("unzip", ["-p", file, name], {
        encoding: "buffer",
        maxBuffer: 1 << 24,
      })
    ).stdout;

  test("holds color.jpg and alpha.png", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 90;
    const result = await render(
      { format: "zip" },
      { image: solidImage(W, H), alpha },
    );
    assert.equal(result.format, "zip");
    assert.equal(result.mime, "application/zip");
    assert.equal(result.width, W);
    assert.equal(result.height, H);

    const file = await saveZip("basic.zip", result.buffer);
    assert.deepEqual(await listEntries(file), ["color.jpg", "alpha.png"]);

    const matte = await decodeMatte(
      await extractEntry(file, "alpha.png"),
      W,
      H,
    );
    assert.deepEqual(matte.data, Buffer.from(alpha));

    const color = await decode(await extractEntry(file, "color.jpg"));
    assert.equal(color.channels, 3);
    assert.equal(color.width, W);
    assert.equal(color.height, H);
    assertNear(pixel(color, 20, 15), FLAT, JPEG_TOLERANCE, "subject");
  });

  test("keeps the original colours unflattened where the mask is clear", async () => {
    const result = await render({ format: "zip" }, { image: solidImage(W, H) });
    const file = await saveZip("unflattened.zip", result.buffer);
    const color = await decode(await extractEntry(file, "color.jpg"));
    assertNear(
      pixel(color, 2, 2),
      FLAT,
      JPEG_TOLERANCE,
      "masked-out pixel keeps its colour",
    );
  });

  test("leaves padding black and transparent past the image edge", async () => {
    const corner = { x: 0, y: 0, w: 10, h: 10 };
    const result = await render(
      { format: "zip", crop: true, cropMargin: sides(px(4)) },
      { image: solidImage(W, H), alpha: rectMask(W, H, corner) },
    );
    assert.equal(result.width, 18);
    assert.equal(result.height, 18);
    const file = await saveZip("padded.zip", result.buffer);
    const color = await decode(await extractEntry(file, "color.jpg"));
    const matte = await decode(await extractEntry(file, "alpha.png"));
    assert.equal(color.width, 18);
    assert.equal(matte.width, 18);
    assert.equal(matte.channels, 1);
    assert.equal(matte.data.length, 18 * 18);
    assertNear(pixel(color, 1, 1), [0, 0, 0], JPEG_TOLERANCE, "padding colour");
    assert.equal(matte.data[1 * 18 + 1], 0);
    assert.equal(matte.data[4 * 18 + 4], 255);
    assertNear(pixel(color, 8, 8), FLAT, JPEG_TOLERANCE, "subject colour");
  });

  test("passes unzip's integrity test", async () => {
    const result = await render({ format: "zip" });
    const file = await saveZip("integrity.zip", result.buffer);
    const { stdout } = await exec("unzip", ["-t", file]);
    assert.match(stdout, /No errors detected/);
  });
});

describe("input checks", () => {
  test("rejects a mask that does not match the image", async () => {
    await assert.rejects(
      render({}, { alpha: new Uint8Array(W * H - 1) }),
      /Alpha mask has/,
    );
  });

  test("rejects pixel data that is not raw RGB for the stated size", async () => {
    const image = { ...gradientImage(W, H), width: W + 1 };
    await assert.rejects(render({}, { image }), /raw RGB/);
  });

  test("rejects unknown size and format values", async () => {
    await assert.rejects(render({ size: "huge" }), /Unknown size/);
    await assert.rejects(render({ format: "gif" }), /Unknown format/);
    await assert.rejects(render({ channels: "rgb" }), /Unknown channels/);
  });
});
