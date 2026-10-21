import { describe, test } from "node:test";
import assert from "node:assert/strict";
import sharp from "sharp";
import { JPEG_QUALITY, compose } from "../src/engine/compose.js";
import {
  FLAT,
  H,
  SUBJECT,
  W,
  alphaPlane,
  assertNear,
  decode,
  gradientImage,
  opts,
  pixel,
  px,
  rectMask,
  render,
  sides,
  solidImage,
  unzipEntries,
} from "./compose.helpers.test.js";

describe("JPEG quality", () => {
  test("encodes at quality 92, like remove.bg's canvas export", async () => {
    assert.equal(JPEG_QUALITY, 92);
    const image = gradientImage(W, H);
    const opaque = new Uint8Array(W * H).fill(255);
    const result = await compose({ image, alpha: opaque, options: opts() });
    assert.equal(result.format, "jpg");

    const encode = (quality) =>
      sharp(image.data, { raw: { width: W, height: H, channels: 3 } })
        .jpeg({ quality })
        .toBuffer();
    assert.deepEqual(result.buffer, await encode(92));
    assert.notDeepEqual(result.buffer, await encode(90));
  });
});

describe("colour under transparent pixels", () => {
  const HIDDEN = [0, 0, 0, 0];

  test("png has RGB 0 wherever alpha is 0, and keeps colour elsewhere", async () => {
    const image = gradientImage(W, H);
    const alpha = rectMask(W, H, SUBJECT);
    alpha[12 * W + 15] = 128; // translucent pixels keep their colour
    const result = await compose({
      image,
      alpha,
      options: opts({ format: "png" }),
    });
    const out = await decode(result.buffer);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const got = pixel(out, x, y);
        if (alpha[y * W + x] === 0) {
          assert.deepEqual(got, HIDDEN, `(${x},${y})`);
          continue;
        }
        const i = (y * W + x) * 3;
        assert.deepEqual(got.slice(0, 3), [...image.data.subarray(i, i + 3)]);
      }
    }
  });

  test("a fully transparent background colour leaves RGB 0, not that colour", async () => {
    const result = await render(
      { bgColor: { r: 10, g: 200, b: 30, alpha: 0 } },
      { image: solidImage(W, H) },
    );
    assert.equal(result.format, "png");
    assert.deepEqual(pixel(await decode(result.buffer), 2, 2), HIDDEN);
  });

  test("webp has RGB 0 in transparent areas", async () => {
    // Fully transparent 16x16 blocks, so lossy coding cannot smear colour in.
    const size = 64;
    const result = await render(
      { format: "webp" },
      {
        image: solidImage(size, size),
        alpha: rectMask(size, size, { x: 32, y: 32, w: 32, h: 32 }),
      },
    );
    const out = await decode(result.buffer);
    for (const [x, y] of [
      [2, 2],
      [20, 20],
      [5, 40],
    ]) {
      assertNear(pixel(out, x, y), HIDDEN, 2, `(${x},${y})`);
    }
    assertNear(pixel(out, 50, 50), [...FLAT, 255], 6, "subject");
  });

  test("zip's color.jpg keeps the original colours under alpha 0", async () => {
    const result = await render({ format: "zip" }, { image: solidImage(W, H) });
    const { "color.jpg": jpeg, "alpha.png": matte } = await unzipEntries(
      result.buffer,
    );
    assertNear(pixel(await decode(jpeg), 2, 2), FLAT, 12, "colour");
    assert.equal((await decode(matte)).data[2 * W + 2], 0);
  });
});

// WebP has no density field of its own; the EXIF block carries XResolution.
const exifXResolution = (exif) => {
  const tiff = exif.subarray(exif.indexOf("Exif\0\0") === 0 ? 6 : 0);
  const little = tiff.toString("latin1", 0, 2) === "II";
  const u16 = (at) => (little ? tiff.readUInt16LE(at) : tiff.readUInt16BE(at));
  const u32 = (at) => (little ? tiff.readUInt32LE(at) : tiff.readUInt32BE(at));
  const ifd = u32(4);
  for (let i = 0; i < u16(ifd); i++) {
    const entry = ifd + 2 + i * 12;
    if (u16(entry) !== 0x011a) continue;
    return u32(u32(entry + 8)) / u32(u32(entry + 8) + 4);
  }
  return undefined;
};

const densityOf = async (buffer, format) => {
  const meta = await sharp(buffer).metadata();
  return format === "webp" ? exifXResolution(meta.exif) : meta.density;
};

describe("density", () => {
  const FORMATS = ["png", "jpg", "webp"];
  const withDensity = (format, density) =>
    render({ format }, { image: solidImage(W, H), density });

  test("is written into png, jpg and webp outputs", async () => {
    for (const format of FORMATS) {
      const { buffer } = await withDensity(format, 300);
      assert.equal(await densityOf(buffer, format), 300, format);
    }
  });

  test("is rounded to a whole number", async () => {
    for (const [density, expected] of [
      [96.4, 96],
      [299.6, 300],
    ]) {
      for (const format of FORMATS) {
        const { buffer } = await withDensity(format, density);
        assert.equal(await densityOf(buffer, format), expected, format);
      }
    }
  });

  test("is left out when absent, not defaulted to 72", async () => {
    const plain = await withDensity("png", undefined);
    assert.equal((await sharp(plain.buffer).metadata()).density, undefined);
    // Without a density no EXIF block is written either.
    for (const format of FORMATS) {
      const { buffer } = await withDensity(format, undefined);
      assert.equal((await sharp(buffer).metadata()).exif, undefined, format);
      assert.deepEqual(buffer, (await withDensity(format, null)).buffer);
    }
  });

  test("applies to the alpha matte and the zip's files", async () => {
    const matte = await render(
      { channels: "alpha" },
      { image: solidImage(W, H), density: 150 },
    );
    assert.equal((await sharp(matte.buffer).metadata()).density, 150);

    const zip = await render(
      { format: "zip" },
      { image: solidImage(W, H), density: 150 },
    );
    const entries = await unzipEntries(zip.buffer);
    for (const name of ["color.jpg", "alpha.png"]) {
      assert.equal((await sharp(entries[name]).metadata()).density, 150, name);
    }
  });

  test("does not change the pixels", async () => {
    const plain = await decode((await withDensity("png", undefined)).buffer);
    const tagged = await decode((await withDensity("png", 300)).buffer);
    assert.deepEqual(tagged.data, plain.data);
    assert.deepEqual(alphaPlane(tagged), alphaPlane(plain));
  });

  test("rejects a density that is not a positive number", async () => {
    for (const density of [0, -72, Number.NaN, Infinity, "300", {}]) {
      await assert.rejects(
        render({}, { density }),
        /Invalid density/,
        String(density),
      );
    }
    // Resolved before any work: a tiny value still writes at least 1.
    await assert.doesNotReject(withDensity("png", 0.2));
  });

  test("works with crop geometry", async () => {
    const result = await render(
      { crop: true, cropMargin: sides(px(2)), format: "png" },
      { density: 200 },
    );
    assert.equal(result.width, SUBJECT.w + 4);
    assert.equal((await sharp(result.buffer).metadata()).density, 200);
  });
});
