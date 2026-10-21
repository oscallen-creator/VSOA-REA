import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  ForegroundError,
  SUBJECT_ALPHA_THRESHOLD,
  applyRoi,
  compose,
  findSubjectBox,
  fitToMaxPixels,
} from "../src/engine/compose.js";
import {
  FLAT,
  H,
  PNG_SIGNATURE,
  SUBJECT,
  W,
  alphaPlane,
  assertNear,
  countAbove,
  decode,
  gradientImage,
  imageRgb,
  opaqueBounds,
  opts,
  pct,
  pixel,
  px,
  rectMask,
  render,
  sides,
  solidImage,
} from "./compose.helpers.test.js";

const SUBJECT_BOX = {
  left: SUBJECT.x,
  top: SUBJECT.y,
  width: SUBJECT.w,
  height: SUBJECT.h,
};

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
        shadowType: "drop",
        shadowOpacity: 0.5,
      }),
    });
    assert.deepEqual(image.data, pixelsBefore);
    assert.deepEqual(alpha, alphaBefore);
  });

  test("reports the subject box in original pixels", async () => {
    assert.deepEqual((await render()).subjectBox, SUBJECT_BOX);
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

  test("applyRoi converts percentages, clamps, and passes through", () => {
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

    const clamped = applyRoi(alpha, [px(-5), px(-5), px(500), px(500)], W, H);
    assert.deepEqual(clamped, alpha);
    const inverted = applyRoi(alpha, [px(20), px(20), px(10), px(10)], W, H);
    assert.ok(inverted.every((value) => value === 0));
    const mask = rectMask(W, H, SUBJECT);
    assert.deepEqual(applyRoi(mask, null, W, H), mask);
  });

  test("throws ForegroundError when the mask lies outside or the ROI is empty", async () => {
    for (const roi of [
      [px(0), px(0), px(8), px(4)],
      [px(20), px(10), px(20), px(25)],
    ]) {
      await assert.rejects(render({ roi }), ForegroundError);
    }
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
    for (const [x, y] of [
      [0, 0],
      [19, 19],
    ]) {
      const source = imageRgb(image, SUBJECT.x + x, SUBJECT.y + y);
      assert.deepEqual(pixel(out, x, y), [...source, 255]);
    }
  });

  // Margins are measured against the subject: top/bottom use its height,
  // left/right its width, each capped at half of that and at 500 px.
  const rect20x10 = { x: 10, y: 5, w: 20, h: 10 };
  const MARGINS = [
    {
      name: "pixels on every side",
      margin: sides(px(3)),
      size: [26, 26],
      bounds: { left: 3, top: 3, width: 20, height: 20 },
    },
    {
      name: "four different pixel margins",
      margin: { top: px(2), right: px(4), bottom: px(6), left: px(8) },
      size: [32, 28],
      bounds: { left: 8, top: 2, width: 20, height: 20 },
    },
    {
      name: "percent of the matching subject dimension",
      margin: { top: pct(40), right: pct(25), bottom: pct(10), left: pct(50) },
      rect: rect20x10,
      size: [35, 15], // 4 + 10 + 1 tall; 10 + 20 + 5 wide
    },
    {
      name: "pixel cap of half the subject",
      margin: sides(px(1000)),
      rect: rect20x10,
      size: [40, 20],
    },
    {
      name: "percent cap of half the subject",
      margin: sides(pct(300)),
      rect: rect20x10,
      size: [40, 20],
    },
    {
      name: "rounded fractional margins",
      margin: { top: px(0), right: pct(10), bottom: px(0), left: px(0) },
      rect: { x: 10, y: 5, w: 25, h: 10 },
      size: [25 + Math.round(2.5), 10],
    },
  ];

  for (const { name, margin, rect = SUBJECT, size, bounds } of MARGINS) {
    test(`adds margins: ${name}`, async () => {
      const result = await render(
        { crop: true, cropMargin: margin },
        { alpha: rectMask(W, H, rect) },
      );
      assert.deepEqual([result.width, result.height], size);
      if (bounds) {
        assert.deepEqual(opaqueBounds(await decode(result.buffer)), bounds);
      }
    });
  }

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
});

describe("crop placement", () => {
  const margin = { crop: true, cropMargin: sides(px(4)) };

  test("fills margins that fall inside the image with transparent pixels", async () => {
    const image = gradientImage(W, H);
    const result = await render(
      { crop: true, cropMargin: sides(px(3)) },
      { image },
    );
    const out = await decode(result.buffer);
    // Hidden pixels are RGB 0 (see the PNG rules), the subject keeps its colour.
    assert.deepEqual(pixel(out, 0, 0), [0, 0, 0, 0]);
    assert.deepEqual(pixel(out, 3, 3), [
      ...imageRgb(image, SUBJECT.x, SUBJECT.y),
      255,
    ]);
  });

  test("pads transparently where margins pass the image edges", async () => {
    const image = gradientImage(W, H);
    const corners = [
      // Subject in the top-left corner: top row and left column are padding.
      {
        rect: { x: 0, y: 0, w: 10, h: 10 },
        edge: (i) => [
          [i, 0],
          [0, i],
        ],
      },
      // Subject in the bottom-right corner: bottom row and right column.
      {
        rect: { x: 30, y: 20, w: 10, h: 10 },
        edge: (i) => [
          [i, 17],
          [17, i],
        ],
      },
    ];
    for (const { rect, edge } of corners) {
      const result = await render(margin, {
        image,
        alpha: rectMask(W, H, rect),
      });
      assert.equal(result.width, 18);
      assert.equal(result.height, 18);
      const out = await decode(result.buffer);
      for (let i = 0; i < 18; i++) {
        for (const [x, y] of edge(i)) {
          assert.deepEqual(pixel(out, x, y), [0, 0, 0, 0], `(${x},${y})`);
        }
      }
      assert.deepEqual(opaqueBounds(out), {
        left: 4,
        top: 4,
        width: 10,
        height: 10,
      });
    }
  });

  test("ignores scale and position", async () => {
    const plain = await render({ ...margin, cropMargin: sides(px(2)) });
    const extras = await render({
      ...margin,
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
});

describe("scale and position", () => {
  const CASES = [
    // factor = scale * min(40/20, 30/20) = 0.75 -> 15x15 at (round(12.5), round(7.5)).
    [{ scale: 0.5, position: { x: 0.5, y: 0.5 } }, [13, 8, 15, 15]],
    [{ scale: 0.5 }, [13, 8, 15, 15]], // position defaults to the centre
    [{ scale: 1, position: { x: 0.5, y: 0.5 } }, [5, 0, 30, 30]], // factor 1.5
    [{ scale: 0.5, position: { x: 1, y: 0 } }, [25, 0, 15, 15]],
    [{ position: { x: 0, y: 0 } }, [0, 0, 20, 20]],
    [{ position: { x: 1, y: 1 } }, [20, 10, 20, 20]],
  ];

  for (const [overrides, [left, top, width, height]] of CASES) {
    test(`places the subject for ${JSON.stringify(overrides)}`, async () => {
      const result = await render(overrides, { image: solidImage(W, H) });
      assert.equal(result.width, W);
      assert.equal(result.height, H);
      const out = await decode(result.buffer);
      assert.deepEqual(opaqueBounds(out), { left, top, width, height });
      assert.equal(countAbove(out, 0), width * height);
      assertNear(pixel(out, left + 5, top + 5), [...FLAT, 255], 2, "inside");
      // The reported box stays in original image coordinates.
      assert.deepEqual(result.subjectBox, SUBJECT_BOX);
    });
  }

  test("moves the subject's own pixels to the corner", async () => {
    const image = gradientImage(W, H);
    const top = await decode(
      (await render({ position: { x: 0, y: 0 } }, { image })).buffer,
    );
    assert.deepEqual(pixel(top, 0, 0), [...imageRgb(image, 10, 5), 255]);
    assert.deepEqual(pixel(top, 19, 19), [...imageRgb(image, 29, 24), 255]);
    const end = await decode(
      (await render({ position: { x: 1, y: 1 } }, { image })).buffer,
    );
    assert.deepEqual(pixel(end, 20, 10), [...imageRgb(image, 10, 5), 255]);
    assert.deepEqual(pixel(end, 39, 29), [...imageRgb(image, 29, 24), 255]);
  });

  test("moves only the subject box, not faint pixels outside it", async () => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[1 * W + 1] = SUBJECT_ALPHA_THRESHOLD - 1; // outside the box
    const result = await render({ position: { x: 1, y: 1 } }, { alpha });
    const out = await decode(result.buffer);
    assert.equal(countAbove(out, 0), SUBJECT.w * SUBJECT.h);
  });
});

describe("size", () => {
  const big = (rect) => ({
    image: solidImage(1000, 1000),
    alpha: rectMask(1000, 1000, rect),
  });
  const BIG_RECT = { x: 100, y: 100, w: 800, h: 800 };

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
    const result = await render({ size: "preview" }, big(BIG_RECT));
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

  test("preview keeps the aspect ratio and uses the budget", async () => {
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
    for (const size of ["full", "auto"]) {
      const result = await render({ size }, big(BIG_RECT));
      assert.equal(result.width, 1000, size);
      assert.equal(result.height, 1000, size);
    }
  });

  test("scales crop margins together with the subject", async () => {
    const result = await render(
      { size: "preview", crop: true, cropMargin: sides(pct(10)) },
      big(BIG_RECT),
    );
    // Canvas 960x960 -> about 500x500.
    assert.ok(result.width >= 499 && result.width <= 500, `${result.width}`);
    assert.equal(result.width, result.height);
    const out = await decode(result.buffer);
    assertNear(pixel(out, 2, 2), [0, 0, 0, 0], 2, "margin corner");
    const middle = Math.floor(out.height / 2);
    let opaque = 0;
    for (let x = 0; x < out.width; x++) {
      if (pixel(out, x, middle)[3] >= 128) opaque++;
    }
    // 800 source pixels * (500 / 960) is about 417.
    assert.ok(Math.abs(opaque - 417) <= 2, `opaque run ${opaque}`);
  });
});
