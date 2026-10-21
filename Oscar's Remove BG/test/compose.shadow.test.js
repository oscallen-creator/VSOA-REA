import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { compose, findSubjectBox } from "../src/engine/compose.js";
import { renderShadow } from "../src/engine/shadow.js";
import sharp from "sharp";
import {
  FLAT,
  JPEG_TOLERANCE,
  alphaPlane,
  assertNear,
  decode,
  decodeMatte,
  opts,
  pixel,
  px,
  rectMask,
  render,
  solidImage,
  unzipEntries,
} from "./compose.helpers.test.js";

// A 140x140 subject on a 240x240 canvas. The drop shadow is offset by
// (round(0.02 * 140), round(0.03 * 140)) = (3, 4) with sigma 2.1, so the
// pixel at (181, 100) lies just outside the subject, inside the shadow.
const SIZE = 240;
const SQUARE = { x: 40, y: 30, w: 140, h: 140 };
const BESIDE = [181, 100];
const FAR = [10, 10];
const DROP = { shadowType: "drop", shadowOpacity: 0.5 };

const scene = (rect = SQUARE) => ({
  image: solidImage(SIZE, SIZE),
  alpha: rectMask(SIZE, SIZE, rect),
});
const draw = (overrides, rect) => render(overrides, scene(rect));
const at = (img, [x, y]) => pixel(img, x, y);

describe("shadow under the subject", () => {
  test("a drop shadow is partly opaque black below and right of the subject", async () => {
    const result = await draw(DROP);
    assert.equal(result.format, "png", "a shadow makes the image translucent");
    assert.deepEqual([result.width, result.height], [SIZE, SIZE]);
    const out = await decode(result.buffer);

    const [r, g, b, a] = at(out, BESIDE);
    assert.deepEqual([r, g, b], [0, 0, 0]);
    assert.ok(a > 40 && a <= 128, `alpha ${a}`);
    const below = at(out, [100, 173]);
    assert.ok(below[3] > 0 && below[3] <= 128, `below ${below[3]}`);
    // Nothing is cast up and to the left, and the subject itself is untouched.
    assert.deepEqual(at(out, FAR), [0, 0, 0, 0]);
    assert.deepEqual(at(out, [60, 20]), [0, 0, 0, 0]);
    assert.deepEqual(at(out, [100, 100]), [...FLAT, 255]);
  });

  test("a contact shadow darkens only the ground under the base", async () => {
    const out = await decode(
      (await draw({ shadowType: "car", shadowOpacity: 0.9 })).buffer,
    );
    const under = at(out, [110, 170]);
    assert.deepEqual(under.slice(0, 3), [0, 0, 0]);
    assert.ok(under[3] > 60 && under[3] <= 230, `alpha ${under[3]}`);
    assert.deepEqual(at(out, [110, 20]), [0, 0, 0, 0]);
    assert.deepEqual(at(out, [110, 120]), [...FLAT, 255]);
    assert.deepEqual(at(out, [181, 100]), [0, 0, 0, 0]);
  });

  test("composites with straight-alpha source-over below translucent pixels", async () => {
    const image = solidImage(SIZE, SIZE);
    const alpha = rectMask(SIZE, SIZE, SQUARE);
    for (let y = SQUARE.y; y < SQUARE.y + SQUARE.h; y++) {
      alpha[y * SIZE + SQUARE.x + SQUARE.w - 1] = 128; // soft right edge
    }
    const result = await compose({
      image,
      alpha,
      options: opts({ ...DROP, format: "png" }),
    });
    const shadow = await renderShadow({
      alpha,
      width: SIZE,
      height: SIZE,
      box: findSubjectBox(alpha, SIZE, SIZE),
      type: "drop",
      opacity: 0.5,
    });
    const out = await decode(result.buffer);
    for (let i = 0; i < SIZE * SIZE; i++) {
      const subject = alpha[i] / 255;
      const outAlpha = subject + (shadow[i] / 255) * (1 - subject);
      const expected = FLAT.map((c) => Math.round((c * subject) / outAlpha));
      const got = pixel(out, i % SIZE, Math.floor(i / SIZE));
      if (outAlpha === 0) {
        assert.deepEqual(got, [0, 0, 0, 0], `pixel ${i}`);
        continue;
      }
      assertNear(
        got,
        [...expected, Math.round(outAlpha * 255)],
        1,
        `pixel ${i}`,
      );
    }
  });
});

describe("shadow and the rest of the pipeline", () => {
  test("none, or opacity 0, leaves the output byte for byte as without a shadow", async () => {
    const plain = await draw({});
    for (const overrides of [
      { shadowType: "none", shadowOpacity: 0.9 },
      { shadowType: "drop", shadowOpacity: 0 },
    ]) {
      const result = await draw(overrides);
      assert.deepEqual(result.buffer, plain.buffer, JSON.stringify(overrides));
    }
  });

  test("a scaled subject carries its shadow along", async () => {
    // 0.5 * 240 / 140 shrinks the subject to 120x120; position 0% 0% puts it at
    // the top-left, so the shadow lands beside it, not beside the original box.
    const scaled = await draw({
      ...DROP,
      channels: "alpha",
      scale: 0.5,
      position: { x: 0, y: 0 },
    });
    const matte = await decodeMatte(scaled.buffer, SIZE, SIZE);
    assert.ok(matte.data[60 * SIZE + 121] > 40, "beside the scaled subject");
    assert.equal(matte.data[BESIDE[1] * SIZE + BESIDE[0]], 0);
  });

  test("a crop clips the shadow to its canvas", async () => {
    const alphaOf = async (margin) => {
      const cropMargin = {
        top: px(margin),
        right: px(margin),
        bottom: px(margin),
        left: px(margin),
      };
      const result = await draw({
        ...DROP,
        channels: "alpha",
        crop: true,
        cropMargin,
      });
      return decodeMatte(result.buffer, result.width, result.height);
    };
    // No margin: the canvas is exactly the subject, so the shadow is all clipped.
    assert.ok((await alphaOf(0)).data.every((value) => value === 255));
    const margin = await alphaOf(10);
    assert.equal(margin.width, SQUARE.w + 20);
    assert.ok(margin.data[80 * margin.width + 151] > 40, "room for the shadow");
  });

  test("a downscaled preview casts after the size cap", async () => {
    const big = {
      image: solidImage(1000, 1000),
      alpha: rectMask(1000, 1000, { x: 100, y: 100, w: 800, h: 800 }),
    };
    const result = await render(
      { ...DROP, size: "preview", channels: "alpha" },
      big,
    );
    const matte = await decodeMatte(result.buffer, 500, 500);
    // The subject fills 50..449; its shadow is offset by (8, 12) with sigma 6.
    assert.equal(matte.data[250 * 500 + 440], 255);
    assert.ok(matte.data[250 * 500 + 452] > 40, "beside the subject");
    assert.equal(matte.data[250 * 500 + 480], 0, "well past the blur");
  });

  test("a subject touching the canvas edge still composes", async () => {
    const corner = { x: SIZE - 100, y: SIZE - 100, w: 100, h: 100 };
    for (const shadowType of ["drop", "car", "3D", "auto"]) {
      const result = await draw({ shadowType, shadowOpacity: 0.8 }, corner);
      const out = await decode(result.buffer);
      assert.deepEqual(
        at(out, [SIZE - 50, SIZE - 50]),
        [...FLAT, 255],
        shadowType,
      );
      assert.deepEqual(at(out, FAR), [0, 0, 0, 0], shadowType);
    }
  });
});

describe("shadow with backgrounds and other outputs", () => {
  test("darkens a background colour; the output is then a JPEG", async () => {
    const bgColor = { r: 200, g: 200, b: 200, alpha: 1 };
    const result = await draw({ ...DROP, shadowOpacity: 1, bgColor });
    assert.equal(result.format, "jpg");
    const out = await decode(result.buffer);
    assertNear(at(out, FAR), [200, 200, 200], JPEG_TOLERANCE, "far");
    const [r, g, b] = at(out, BESIDE);
    assert.ok(
      r < 150 && g < 150 && b < 150,
      `beside the subject: ${r},${g},${b}`,
    );
    assert.ok(r > 0, "a soft edge, not solid black");
  });

  test("darkens a background image", async () => {
    const bgImage = await sharp(Buffer.alloc(8 * 8 * 3, 180), {
      raw: { width: 8, height: 8, channels: 3 },
    })
      .png()
      .toBuffer();
    const result = await draw({
      ...DROP,
      shadowOpacity: 1,
      bgImage,
      format: "png",
    });
    const out = await decode(result.buffer);
    assertNear(at(out, FAR), [180, 180, 180, 255], 1, "far");
    assert.ok(at(out, BESIDE)[0] < 130);
  });

  test("the zip's colour and alpha files include the shadow", async () => {
    const entries = await unzipEntries(
      (await draw({ ...DROP, format: "zip" })).buffer,
    );
    const matte = await decodeMatte(entries["alpha.png"], SIZE, SIZE);
    assert.ok(matte.data[BESIDE[1] * SIZE + BESIDE[0]] > 40);
    const color = await decode(entries["color.jpg"]);
    // Black shadow colour beside the subject; the untouched source far away.
    assertNear(at(color, BESIDE), [0, 0, 0], JPEG_TOLERANCE, "shadow colour");
    assertNear(at(color, FAR), FLAT, JPEG_TOLERANCE, "source colour");
  });

  test("the alpha channel includes the shadow, as in the RGBA output", async () => {
    const withShadow = await draw({ ...DROP, channels: "alpha" });
    const matte = await decodeMatte(withShadow.buffer, SIZE, SIZE);
    assert.ok(matte.data[BESIDE[1] * SIZE + BESIDE[0]] > 40);
    assert.equal(matte.data[FAR[1] * SIZE + FAR[0]], 0);

    const rgba = await decode((await draw(DROP)).buffer);
    assert.deepEqual(alphaPlane(rgba), matte.data);

    const without = await draw({ channels: "alpha" });
    const bare = await decodeMatte(without.buffer, SIZE, SIZE);
    assert.equal(bare.data[BESIDE[1] * SIZE + BESIDE[0]], 0);
  });

  test("the subject box stays the original image's", async () => {
    const result = await draw(DROP);
    assert.deepEqual(result.subjectBox, {
      left: SQUARE.x,
      top: SQUARE.y,
      width: SQUARE.w,
      height: SQUARE.h,
    });
  });
});
