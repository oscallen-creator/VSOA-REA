import { describe, test } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { ForegroundError, compose } from "../src/engine/compose.js";
import {
  FLAT,
  H,
  JPEG_TOLERANCE,
  SUBJECT,
  W,
  alphaPlane,
  assertNear,
  decode,
  decodeMatte,
  gradientImage,
  opts,
  pixel,
  px,
  rectMask,
  render,
  rgb,
  sides,
  solidImage,
  testZip,
  unzipEntries,
} from "./compose.helpers.test.js";

describe("background colour", () => {
  const green = { r: 10, g: 200, b: 30, alpha: 1 };
  // A subject with one soft pixel at (12, 10).
  const softMask = (value = 128) => {
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = value;
    return alpha;
  };

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
    const result = await render(
      { bgColor: green, format: "png" },
      { image: solidImage(W, H), alpha: softMask() },
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
    const result = await render(
      { bgColor: { ...green, alpha: 0.5 } },
      { image: solidImage(W, H), alpha: softMask() },
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
    for (let x = 0; x < width; x++) {
      data.set(colorAt(x, y), (y * width + x) * 3);
    }
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
    const result = await render(
      { bgImage, format: "png" },
      { image: solidImage(W, H) },
    );
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
    const alpha = rectMask(20, 40, { x: 5, y: 15, w: 10, h: 10 });
    const result = await render(
      { bgImage: stored, format: "png" },
      { image: solidImage(20, 40), alpha },
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
    const alpha = rectMask(W, H, SUBJECT);
    alpha[10 * W + 12] = 128;
    const result = await render(
      { bgImage: await rawPng(8, 8, () => BLUE), format: "png" },
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

    const entries = await unzipEntries(result.buffer);
    assert.deepEqual(Object.keys(entries), ["color.jpg", "alpha.png"]);
    const matte = await decodeMatte(entries["alpha.png"], W, H);
    assert.deepEqual(matte.data, Buffer.from(alpha));

    const color = await decode(entries["color.jpg"]);
    assert.equal(color.channels, 3);
    assert.equal(color.width, W);
    assert.equal(color.height, H);
    assertNear(pixel(color, 20, 15), FLAT, JPEG_TOLERANCE, "subject");
    // Unlike the PNG, the colours stay where the mask is clear.
    assertNear(pixel(color, 2, 2), FLAT, JPEG_TOLERANCE, "masked-out pixel");
  });

  test("keeps real colours in margins inside the image, black past its edge", async () => {
    const corner = { x: 0, y: 0, w: 10, h: 10 };
    const result = await render(
      { format: "zip", crop: true, cropMargin: sides(px(4)) },
      { image: solidImage(W, H), alpha: rectMask(W, H, corner) },
    );
    assert.equal(result.width, 18);
    assert.equal(result.height, 18);
    const entries = await unzipEntries(result.buffer);
    const color = await decode(entries["color.jpg"]);
    const matte = await decode(entries["alpha.png"]);
    assert.equal(color.width, 18);
    assert.equal(matte.width, 18);
    assert.equal(matte.channels, 1);
    assert.equal(matte.data.length, 18 * 18);
    assertNear(pixel(color, 1, 1), [0, 0, 0], JPEG_TOLERANCE, "padding");
    assertNear(pixel(color, 16, 16), FLAT, JPEG_TOLERANCE, "inside margin");
    assertNear(pixel(color, 8, 8), FLAT, JPEG_TOLERANCE, "subject");
    assert.equal(matte.data[1 * 18 + 1], 0);
    assert.equal(matte.data[4 * 18 + 4], 255);
  });

  test("passes unzip's integrity test", async () => {
    const result = await render({ format: "zip" });
    assert.match(await testZip(result.buffer), /No errors detected/);
  });
});

describe("input checks", () => {
  test("rejects a mask or pixel data that does not match the image", async () => {
    await assert.rejects(
      render({}, { alpha: new Uint8Array(W * H - 1) }),
      /Alpha mask has/,
    );
    const image = { ...gradientImage(W, H), width: W + 1 };
    await assert.rejects(render({}, { image }), /raw RGB/);
  });

  test("rejects unknown size, format, channels and shadow type values", async () => {
    await assert.rejects(render({ size: "huge" }), /Unknown size/);
    await assert.rejects(render({ format: "gif" }), /Unknown format/);
    await assert.rejects(render({ channels: "rgb" }), /Unknown channels/);
    await assert.rejects(
      render({ shadowType: "glow", shadowOpacity: 0.5 }),
      /Unknown shadow type "glow"/,
    );
  });

  test("accepts options without the shadow fields, as before shadows", async () => {
    const legacy = opts();
    delete legacy.shadowType;
    delete legacy.shadowOpacity;
    const result = await compose({
      image: gradientImage(W, H),
      alpha: rectMask(W, H, SUBJECT),
      options: legacy,
    });
    const plain = await render();
    assert.deepEqual(result.buffer, plain.buffer);
  });
});
