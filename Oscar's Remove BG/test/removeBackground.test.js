import { after, afterEach, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { crc32, deflateSync } from "node:zlib";
import sharp from "sharp";
import { ModelDownloadError } from "../src/engine/modelStore.js";
import { DEFAULT_MODEL_ID, MODELS } from "../src/engine/models.js";
import { OptionError } from "../src/engine/options.js";
import { createRemover, decodeImage } from "../src/engine/removeBackground.js";

const FLAT = [200, 100, 50];
const RED = [255, 0, 0];
const BLUE = [0, 0, 255];
const WHITE = [255, 255, 255];

const solid = (width, height, [r, g, b] = FLAT) =>
  sharp({ create: { width, height, channels: 3, background: { r, g, b } } });

/** Raw RGB pixels from `colour(x, y)`, as an encodable sharp image. */
const painted = (width, height, colour) => {
  const data = Buffer.alloc(width * height * 3);
  for (let i = 0; i < width * height; i += 1) {
    data.set(colour(i % width, Math.floor(i / width)), i * 3);
  }
  return sharp(data, { raw: { width, height, channels: 3 } });
};

/** Left half red, right half blue. */
const halves = (width, height) =>
  painted(width, height, (x) => (x < width / 2 ? RED : BLUE));

const px = ({ data, width, channels }, x, y) => {
  const start = (y * width + x) * channels;
  return [...data.subarray(start, start + channels)];
};

const near = (actual, expected, tolerance = 0) =>
  assert.ok(
    actual.every((value, i) => Math.abs(value - expected[i]) <= tolerance),
    `[${actual}] is not within ${tolerance} of [${expected}]`,
  );

const rawPixels = async (buffer) => {
  const { data, info } = await sharp(buffer)
    .raw()
    .toBuffer({ resolveWithObject: true });
  return { data, width: info.width, channels: info.channels };
};

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const chunk = (type, data) => {
  const body = Buffer.concat([Buffer.from(type), data]);
  const [length, crc] = [Buffer.alloc(4), Buffer.alloc(4)];
  length.writeUInt32BE(data.length);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
};

/** A PNG file with these IHDR fields around already-filtered scanlines. */
const pngFile = (width, height, [depth, colorType], scanlines) => {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([depth, colorType], 8);
  return Buffer.concat([
    PNG_SIGNATURE,
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(scanlines)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
};

/**
 * A one-row 16-bit PNG. `colorType` is 0 (gray), 2 (RGB), 4 (gray + alpha) or
 * 6 (RGBA); `samples` are interleaved values from 0 to 65535.
 */
const png16 = (colorType, samples) => {
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  const row = Buffer.alloc(1 + samples.length * 2);
  samples.forEach((sample, i) => row.writeUInt16BE(sample, 1 + i * 2));
  return pngFile(samples.length / channels, 1, [16, colorType], row);
};

describe("decodeImage pixels", () => {
  for (const name of ["png", "jpeg", "webp", "tiff"]) {
    test(`decodes ${name} to 3-channel 8-bit RGB`, async () => {
      const input = await solid(13, 7).toFormat(name).toBuffer();
      const { image, format } = await decodeImage(input);
      assert.equal(format, name);
      assert.deepEqual([image.width, image.height, image.channels], [13, 7, 3]);
      assert.ok(Buffer.isBuffer(image.data));
      assert.equal(image.data.length, 13 * 7 * 3);
      near(px(image, 6, 3), FLAT, 6);
    });
  }

  test("flattens transparency over white, in 8 and 16 bits", async () => {
    const rgba = [255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 0, 128, 255, 255, 255, 0];
    const wide = rgba.map((value) => value * 257);
    const raw = { raw: { width: 4, height: 1, channels: 4 } };
    const inputs = [
      await sharp(Buffer.from(rgba), raw).png().toBuffer(),
      png16(6, wide),
    ];
    for (const input of inputs) {
      const { image } = await decodeImage(input);
      assert.deepEqual(px(image, 0, 0), WHITE, "transparent red is white");
      assert.deepEqual(px(image, 1, 0), [0, 255, 0], "opaque is untouched");
      near(px(image, 2, 0), [127, 127, 127], 1);
      assert.deepEqual(px(image, 3, 0), WHITE);
    }
  });

  test("decodes a 16-bit PNG to 8-bit values", async () => {
    const samples = [0, 0, 0, 0x4040, 0x4040, 0x4040, 0x8080, 0, 0xffff];
    const input = png16(2, samples);
    assert.equal((await sharp(input).metadata()).depth, "ushort");
    const { image } = await decodeImage(input);
    assert.deepEqual([...image.data], [0, 0, 0, 64, 64, 64, 128, 0, 255]);
  });

  test("turns grayscale into 3 equal channels", async () => {
    const gray = [0, 100, 200, 255];
    const raw = { raw: { width: 4, height: 1, channels: 1 } };
    const eightBit = sharp(Buffer.from(gray), raw).toColourspace("b-w");
    const wide = gray.map((v) => v * 257);
    const withAlpha = wide.flatMap((v) => [v, 65535]);
    const inputs = [
      await eightBit.png().toBuffer(),
      png16(0, wide),
      png16(4, withAlpha),
    ];
    const expected = gray.flatMap((v) => [v, v, v]);
    for (const input of inputs) {
      assert.match((await sharp(input).metadata()).space, /^(b-w|grey16)$/);
      const { image } = await decodeImage(input);
      assert.deepEqual([...image.data], expected);
    }
  });

  test("converts CMYK to 3 sRGB channels", async () => {
    const input = await solid(9, 5).toColourspace("cmyk").jpeg().toBuffer();
    assert.equal((await sharp(input).metadata()).channels, 4);
    const { image } = await decodeImage(input);
    const [r, g, b] = px(image, 4, 2);
    assert.equal(image.data.length, 9 * 5 * 3);
    assert.ok(r > g && g > b, `still orange: ${[r, g, b]}`);
  });
});

describe("decodeImage orientation", () => {
  // Left half red, right half blue, tagged with each EXIF orientation.
  const cases = [
    { tag: undefined, size: [40, 20], first: RED, last: BLUE },
    { tag: 3, size: [40, 20], first: BLUE, last: RED },
    { tag: 6, size: [20, 40], first: RED, last: BLUE },
    { tag: 8, size: [20, 40], first: BLUE, last: RED },
  ];
  for (const { tag, size, first, last } of cases) {
    test(`applies EXIF orientation ${tag ?? "none"}`, async () => {
      let jpeg = halves(40, 20).jpeg({ quality: 95 });
      if (tag) jpeg = jpeg.withMetadata({ orientation: tag });
      const { image } = await decodeImage(await jpeg.toBuffer());
      assert.deepEqual([image.width, image.height], size);
      assert.equal(image.data.length, size[0] * size[1] * 3);
      near(px(image, 1, 1), first, 12);
      near(px(image, image.width - 2, image.height - 2), last, 12);
    });
  }
});

describe("decodeImage maxPixels", () => {
  const maxPixels = 10_000;
  // At most the limit, most of it used, aspect ratio kept within 1px.
  const assertScaled = ({ image }, [wide, tall]) => {
    const pixels = image.width * image.height;
    assert.ok(pixels <= maxPixels && pixels > 0.9 * maxPixels, `${pixels}`);
    assert.equal(image.data.length, pixels * 3);
    assert.ok(Math.abs(image.height - (image.width * tall) / wide) <= 1);
  };

  test("scales a large image down, keeping aspect and density", async () => {
    const png = halves(400, 300).png().withMetadata({ density: 300 });
    const { image, density } = await decodeImage(await png.toBuffer(), {
      maxPixels,
    });
    assertScaled({ image }, [400, 300]);
    assert.equal(density, 300);
    near(px(image, 1, 1), RED, 3);
    near(px(image, image.width - 2, image.height - 2), BLUE, 3);
  });

  test("bounds the area of an EXIF-rotated image", async () => {
    const jpeg = halves(400, 300).jpeg().withMetadata({ orientation: 6 });
    const decoded = await decodeImage(await jpeg.toBuffer(), { maxPixels });
    assert.ok(decoded.image.height > decoded.image.width, "turned upright");
    assertScaled(decoded, [300, 400]);
  });

  test("never exceeds maxPixels for thin or rounding-prone shapes", async () => {
    const png = await solid(333, 77).png().toBuffer();
    const { image } = await decodeImage(png, { maxPixels: 500 });
    assert.ok(
      image.width * image.height <= 500,
      `${image.width}x${image.height}`,
    );
  });
});

describe("decodeImage metadata and bad input", () => {
  test("returns the input's density, or null when it has none", async () => {
    const png = solid(10, 10).png().withMetadata({ density: 300 });
    const jpeg = solid(10, 10).jpeg().withMetadata({ density: 150 });
    assert.equal((await decodeImage(await png.toBuffer())).density, 300);
    assert.equal((await decodeImage(await jpeg.toBuffer())).density, 150);
    for (const name of ["png", "webp"]) {
      const plain = await solid(10, 10).toFormat(name).toBuffer();
      assert.equal((await decodeImage(plain)).density, null, name);
    }
  });

  test("rejects data that is not a readable image", async () => {
    const png = await solid(50, 50).png().toBuffer();
    const jpeg = await solid(50, 50).jpeg().toBuffer();
    const corrupt = {
      "plain text": Buffer.from("this is not an image"),
      "an empty buffer": Buffer.alloc(0),
      "a truncated PNG header": png.subarray(0, 20),
      "a PNG cut short": png.subarray(0, png.length - 30),
      "a JPEG cut in half": jpeg.subarray(0, jpeg.length >> 1),
    };
    for (const [name, input] of Object.entries(corrupt)) {
      await assert.rejects(decodeImage(input), Error, name);
    }
  });

  test("refuses a decompression bomb before decoding it", async () => {
    // Claims 40000 x 30000 = 1.2 billion pixels, beyond the 1 billion limit.
    const bomb = pngFile(40_000, 30_000, [8, 0], Buffer.alloc(1));
    await assert.rejects(decodeImage(bomb), /pixel limit/);
  });
});

const failingFetch = () => {
  const calls = [];
  const cause = Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
  return Object.assign(
    async (url) => {
      calls.push(url);
      throw new TypeError("fetch failed", { cause });
    },
    { calls },
  );
};

const deferred = () => {
  const gate = {};
  gate.promise = new Promise((resolve, reject) =>
    Object.assign(gate, { resolve, reject }),
  );
  return gate;
};

const until = async (condition, label) => {
  for (let attempt = 0; attempt < 500 && !condition(); attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.ok(condition(), `timed out waiting for ${label}`);
};

// Every remover a test opens is disposed afterwards, whatever the outcome.
const opened = [];
afterEach(async () => {
  await Promise.allSettled(opened.splice(0).map((r) => r.dispose()));
});

const open = (config = {}) => {
  const fetch = failingFetch();
  const remover = createRemover({ modelId: "u2netp", fetch, ...config });
  opened.push(remover);
  return { fetch, remover };
};

describe("createRemover without a model", () => {
  // Failed downloads still create the (empty) model folder.
  let modelDir;
  before(async () => {
    modelDir = await mkdtemp(path.join(tmpdir(), "orbg-no-model-"));
  });
  after(() => rm(modelDir, { recursive: true, force: true }));

  test("describes its model, and rejects an unknown one", () => {
    assert.equal(open({ modelDir }).remover.model.id, "u2netp");
    const { remover } = open({ modelDir, modelId: undefined });
    assert.equal(remover.model, MODELS[DEFAULT_MODEL_ID]);
    const unknown = () => createRemover({ modelId: "nope", modelDir });
    assert.throws(unknown, /Unknown model "nope"/);
  });

  test("prepare() fails as a network error, once per attempt", async () => {
    const { fetch, remover } = open({ modelDir });
    const rejectsAsNetwork = (promise) =>
      assert.rejects(promise, (error) => {
        assert.ok(error instanceof ModelDownloadError, String(error));
        assert.deepEqual([error.code, error.modelId], ["network", "u2netp"]);
        assert.equal(error.url, MODELS.u2netp.url);
        return true;
      });
    const first = remover.prepare();
    assert.equal(remover.prepare(), first, "concurrent callers share it");
    await rejectsAsNetwork(first);
    assert.deepEqual(fetch.calls, [MODELS.u2netp.url]);
    await rejectsAsNetwork(remover.prepare());
    assert.equal(fetch.calls.length, 2, "a later call retries");
    const aborted = remover.prepare({ signal: AbortSignal.abort() });
    await assert.rejects(aborted, { code: "aborted" });
    assert.equal(fetch.calls.length, 2, "a cancelled call never downloads");
  });

  test("bad input fails before any model is downloaded", async () => {
    const { fetch, remover } = open({ modelDir });
    const notAnImage = Buffer.from("not an image");
    const invalid = [
      [{ size: "huge" }, "size"],
      [{ format: "bmp" }, "format"],
      [{ crop: "maybe" }, "crop"],
      [{ bg_color: "not-a-colour" }, "bg_color"],
      [{ nonsense: 1 }, "nonsense"],
      [{ bg_color: "red", bg_image: Buffer.from([1]) }, "bg_color"],
    ];
    // The input is no image, so only option parsing can give these errors.
    for (const [options, parameter] of invalid) {
      await assert.rejects(
        remover.removeBackground(notAnImage, options),
        (error) => {
          assert.ok(error instanceof OptionError, String(error));
          assert.equal(error.code, "invalid_option");
          assert.equal(error.parameter, parameter);
          return true;
        },
      );
    }
    await assert.rejects(remover.removeBackground(notAnImage), (error) => {
      assert.ok(!(error instanceof OptionError), "options were fine");
      assert.ok(!(error instanceof ModelDownloadError), "decoded first");
      return true;
    });
    assert.equal(fetch.calls.length, 0);
  });

  test("dispose() is safe early, twice, and after a failed prepare()", async () => {
    const { remover } = open({ modelDir });
    await remover.dispose();
    await remover.dispose();
    await assert.rejects(remover.prepare(), ModelDownloadError);
    await remover.dispose();
    await remover.dispose();
  });
});

const MODELS_DIR = process.env.OSCARS_REMOVE_BG_MODELS;
const SOURCE_MODEL = MODELS_DIR ? path.join(MODELS_DIR, "u2netp.onnx") : "";
const MODEL_SKIP =
  SOURCE_MODEL && existsSync(SOURCE_MODEL)
    ? false
    : "set OSCARS_REMOVE_BG_MODELS to a directory containing u2netp.onnx";

// The model's size and SHA-256 are fixed in models.js, so only the real file
// passes ensureModel(). A private copy keeps the shared folder untouched.
let cachedDir;
before(async () => {
  if (MODEL_SKIP) return;
  cachedDir = await mkdtemp(path.join(tmpdir(), "orbg-cached-model-"));
  await copyFile(SOURCE_MODEL, path.join(cachedDir, "u2netp.onnx"));
});
after(async () => {
  if (cachedDir) await rm(cachedDir, { recursive: true, force: true });
});

/** The subject is the middle half of the image in each direction. */
const centerMask = ({ width, height }) => {
  const mask = new Uint8Array(width * height);
  const [left, top] = [Math.floor(width / 4), Math.floor(height / 4)];
  for (let y = top; y < top + Math.floor(height / 2); y += 1) {
    mask.fill(255, y * width + left, y * width + left + Math.floor(width / 2));
  }
  return mask;
};

/** A createSegmenterFn stand-in that records how it is used. */
const stubSegmenters = () => {
  const calls = { create: [], segment: [], disposed: 0 };
  const segmenter = {
    segment: async (image) => (calls.segment.push(image), centerMask(image)),
    dispose: async () => void (calls.disposed += 1),
  };
  const createSegmenterFn = async (file, model) => {
    calls.create.push({ file, model });
    return segmenter;
  };
  return { calls, segmenter, createSegmenterFn };
};

const cached = { skip: MODEL_SKIP };

describe("createRemover with a stub segmenter", cached, () => {
  const blue = () => solid(40, 30, BLUE).png().toBuffer();
  const openStub = () => {
    const stub = stubSegmenters();
    const config = {
      modelDir: cachedDir,
      createSegmenterFn: stub.createSegmenterFn,
    };
    return { ...stub, ...open(config) };
  };

  test("prepares the cached model once, without downloading", async () => {
    const { calls, fetch, remover, segmenter } = openStub();
    const both = await Promise.all([remover.prepare(), remover.prepare()]);
    assert.deepEqual(both, [segmenter, segmenter]);
    assert.equal(await remover.prepare(), segmenter);
    const file = path.join(cachedDir, "u2netp.onnx");
    assert.deepEqual(calls.create, [{ file, model: MODELS.u2netp }]);
    assert.equal(fetch.calls.length, 0);
  });

  test("bg_color gives an opaque jpg of the input's size", async () => {
    const { remover } = openStub();
    const options = { bg_color: "ff0000" };
    const result = await remover.removeBackground(await blue(), options);
    assert.equal(result.format, "jpg");
    assert.deepEqual([result.width, result.height], [40, 30]);
    const input = { width: 40, height: 30, density: null, format: "png" };
    assert.deepEqual(result.input, input);
    const out = await rawPixels(result.buffer);
    near(px(out, 2, 2), RED, 20);
    near(px(out, 20, 14), BLUE, 20);
  });

  test("crop keeps just the subject; input describes the original", async () => {
    const { remover } = openStub();
    const options = { crop: true };
    const result = await remover.removeBackground(await blue(), options);
    assert.deepEqual([result.width, result.height], [20, 15]);
    assert.deepEqual([result.input.width, result.input.height], [40, 30]);
  });

  test("segments the upright image and reports its density", async () => {
    const { calls, remover } = openStub();
    const tags = { orientation: 6, density: 300 };
    const jpeg = await solid(40, 20).jpeg().withMetadata(tags).toBuffer();
    const result = await remover.removeBackground(jpeg);
    const [seen] = calls.segment;
    assert.deepEqual([seen.width, seen.height, seen.channels], [20, 40, 3]);
    assert.equal(seen.data.length, 20 * 40 * 3);
    const input = { width: 20, height: 40, density: 300, format: "jpeg" };
    assert.deepEqual(result.input, input);
  });
});

describe("createRemover lifecycle and real model", cached, () => {
  test("dispose waits for a segmenter that is still loading", async () => {
    const [gate, stub] = [deferred(), stubSegmenters()];
    const { remover } = open({
      modelDir: cachedDir,
      createSegmenterFn: async (...args) => {
        await stub.createSegmenterFn(...args);
        return gate.promise;
      },
    });
    const preparing = remover.prepare();
    await until(() => stub.calls.create.length === 1, "the load to start");
    let released = false;
    const disposing = remover.dispose().then(() => (released = true));
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(released, false, "dispose must wait for the load");
    gate.resolve(stub.segmenter);
    await Promise.all([preparing, disposing]);
    assert.equal(stub.calls.disposed, 1);
    await remover.prepare();
    assert.equal(
      stub.calls.create.length,
      2,
      "prepare() restarts after dispose",
    );
  });

  test("a disposed attempt that fails late leaves a newer prepare() alone", async () => {
    const gates = [deferred(), deferred(), deferred()];
    let loads = 0;
    const { remover } = open({
      modelDir: cachedDir,
      createSegmenterFn: () => gates[loads++].promise,
    });
    try {
      remover.prepare().catch(() => {});
      await until(() => loads === 1, "the first load");
      const disposing = remover.dispose();
      const newer = remover.prepare();
      await until(() => loads === 2, "the second load");
      gates[0].reject(new Error("late failure"));
      await disposing;
      const current = remover.prepare();
      current.catch(() => {});
      assert.equal(current, newer, "the newer attempt is still current");
    } finally {
      gates.forEach((gate) => gate.resolve(stubSegmenters().segmenter));
    }
  });

  test("the real u2netp replaces a disc's background, and crops", async () => {
    const [width, height, cx, cy, radius] = [96, 64, 48, 32, 20];
    const inside = (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2;
    const shade = (x, y) => (inside(x, y) ? [240, 240, 240] : [20, 20, 20]);
    const disc = await painted(width, height, shade).png().toBuffer();
    const { fetch, remover } = open({ modelDir: cachedDir });

    const options = { bg_color: "ff0000" };
    const filled = await remover.removeBackground(disc, options);
    assert.equal(filled.format, "jpg");
    assert.deepEqual([filled.width, filled.height], [width, height]);
    assert.deepEqual([filled.input.width, filled.input.height], [96, 64]);
    const out = await rawPixels(filled.buffer);
    near(px(out, 3, 3), RED, 30);
    near(px(out, cx, cy), [240, 240, 240], 30);

    const cropped = await remover.removeBackground(disc, { crop: true });
    assert.ok(cropped.width < width && cropped.height < height);
    assert.ok(cropped.width >= 30 && cropped.height >= 30, "disc kept");
    assert.equal(fetch.calls.length, 0);
  });
});
