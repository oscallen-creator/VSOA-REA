import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import path from "node:path";
import { MODELS } from "../src/engine/models.js";
import {
  createSegmenter,
  toInputTensor,
  toMask,
} from "../src/engine/segment.js";

const closeTo = (actual, expected, tolerance = 1e-6) => {
  assert.equal(actual.length, expected.length, "length");
  actual.forEach((value, i) => {
    assert.ok(
      Math.abs(value - expected[i]) <= tolerance,
      `index ${i} is ${value}, expected ${expected[i]} +/- ${tolerance}`,
    );
  });
};

const plain = { mean: [0, 0, 0], std: [1, 1, 1] };
const specOf = (inputSize, extra = plain) => ({
  id: "fake-net",
  inputSize,
  ...extra,
});

describe("toInputTensor", () => {
  const two = specOf(2);

  test("lays the channels out as planes in R, G, B order", () => {
    const rgb = Uint8Array.from([
      10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120,
    ]);
    // Pixel by pixel above; plane by plane below.
    const planes = [10, 40, 70, 100, 20, 50, 80, 110, 30, 60, 90, 120];
    closeTo(
      toInputTensor(rgb, two),
      planes.map((value) => value / 120),
    );
  });

  test("divides by the brightest value across all channels", () => {
    // The 200 sits in a blue sample, yet it scales the red and green planes too.
    const rgb = Uint8Array.from([50, 0, 0, 0, 100, 0, 0, 0, 200, 100, 50, 25]);
    const tensor = toInputTensor(rgb, two);
    closeTo(tensor.subarray(0, 4), [0.25, 0, 0, 0.5]);
    closeTo(tensor.subarray(4, 8), [0, 0.5, 0, 0.25]);
    closeTo(tensor.subarray(8, 12), [0, 0, 1, 0.125]);
    assert.equal(tensor[10], 1, "the brightest sample maps to exactly 1");
  });

  test("applies each channel's own mean and std after dividing", () => {
    const spec = specOf(2, { mean: [0.5, 0.25, 0.75], std: [0.5, 0.5, 0.25] });
    // Pixels: gray 100, white, black, then (200, 100, 0); the brightest is 200.
    const rgb = Uint8Array.from([
      100, 100, 100, 200, 200, 200, 0, 0, 0, 200, 100, 0,
    ]);
    const expected = [0, 1, -1, 1, 0.5, 1.5, -0.5, 0.5, -1, 1, -3, -3];
    closeTo(toInputTensor(rgb, spec), expected);
  });

  test("keeps an all-black image finite", () => {
    const { mean, std } = MODELS.u2netp;
    const tensor = toInputTensor(new Uint8Array(12), specOf(2, { mean, std }));
    assert.ok(tensor.every(Number.isFinite), "no NaN or Infinity");
    const expected = [0, 1, 2].flatMap((c) => Array(4).fill(-mean[c] / std[c]));
    closeTo(tensor, expected);
  });

  test("does not modify the pixels it reads", () => {
    const rgb = Uint8Array.from({ length: 12 }, (_, i) => i * 10);
    const before = Uint8Array.from(rgb);
    toInputTensor(rgb, two);
    assert.deepEqual(rgb, before);
  });

  for (const size of [1, 3, 5]) {
    test(`returns a Float32Array of 3 * ${size} * ${size} values`, () => {
      const tensor = toInputTensor(
        new Uint8Array(3 * size * size),
        specOf(size),
      );
      assert.ok(tensor instanceof Float32Array);
      assert.equal(tensor.length, 3 * size * size);
    });
  }

  for (const model of Object.values(MODELS)) {
    test(`sizes the tensor for ${model.id}`, () => {
      const pixels = new Uint8Array(3 * model.inputSize * model.inputSize);
      const tensor = toInputTensor(pixels, model);
      assert.equal(tensor.length, 3 * model.inputSize * model.inputSize);
      assert.ok(tensor.every(Number.isFinite));
    });
  }
});

describe("toMask", () => {
  test("scales the lowest value to 0 and the highest to 255", () => {
    const mask = toMask(Float32Array.of(2, 4, 6, 10));
    assert.deepEqual(mask, Uint8Array.of(0, 63, 127, 255));
  });

  test("truncates instead of rounding", () => {
    // Exactly half of the range is 127.5; rounding would give 128.
    assert.deepEqual(
      toMask(Float32Array.of(0, 0.5, 1)),
      Uint8Array.of(0, 127, 255),
    );
    // 0.999 * 255 = 254.7 and 0.0039 * 255 = 0.99 round up but must not.
    assert.deepEqual(
      toMask(Float32Array.of(0, 0.0039, 0.999, 1)),
      Uint8Array.of(0, 0, 254, 255),
    );
  });

  test("maps a constant prediction to zeros without NaN", () => {
    for (const value of [0.7, 0, -3, 1e30]) {
      assert.deepEqual(
        toMask(Float32Array.of(value, value, value)),
        new Uint8Array(3),
      );
    }
    assert.deepEqual(toMask(Float32Array.of(5)), new Uint8Array(1));
    assert.deepEqual(toMask(new Float32Array(0)), new Uint8Array(0));
  });

  test("handles negative ranges", () => {
    assert.deepEqual(
      toMask(Float32Array.of(-4, -3, -2, -1, 0)),
      Uint8Array.of(0, 63, 127, 191, 255),
    );
    assert.deepEqual(
      toMask(Float32Array.of(-10, -5, 0)),
      Uint8Array.of(0, 127, 255),
    );
  });

  test("handles large and tiny ranges", () => {
    assert.deepEqual(
      toMask(Float32Array.of(-1e6, 0, 1e6)),
      Uint8Array.of(0, 127, 255),
    );
    assert.deepEqual(
      toMask(Float32Array.of(-3e38, 0, 3e38)),
      Uint8Array.of(0, 127, 255),
    );
    assert.deepEqual(toMask(Float32Array.of(0, 1e-6)), Uint8Array.of(0, 255));
  });

  test("returns a Uint8Array as long as the prediction", () => {
    let seed = 12345;
    const noise = Float32Array.from({ length: 1000 }, () => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648 - 0.5;
    });
    const mask = toMask(noise);
    assert.ok(mask instanceof Uint8Array);
    assert.equal(mask.length, noise.length);
    assert.equal(Math.min(...mask), 0);
    assert.equal(Math.max(...mask), 255);
    // Larger predictions never get a smaller mask value.
    const order = [...noise.keys()].sort((a, b) => noise[a] - noise[b]);
    for (let i = 1; i < order.length; i += 1) {
      assert.ok(mask[order[i]] >= mask[order[i - 1]], `rank ${i}`);
    }
  });

  test("reads any array-like prediction", () => {
    assert.deepEqual(toMask([0, 1, 2]), Uint8Array.of(0, 127, 255));
  });
});

const SIZE = 8;
const SPEC = specOf(SIZE);

const image = (width, height, pixel) => {
  const data = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const rgb = typeof pixel === "function" ? pixel(x, y) : pixel;
      data.set(rgb, (y * width + x) * 3);
    }
  }
  return { data, width, height, channels: 3 };
};

const at = (mask, width, x, y) => mask[y * width + x];

// A SIZE x SIZE prediction that is high only in the top-left quadrant.
const quadrant = Float32Array.from({ length: SIZE * SIZE }, (_, i) =>
  i % SIZE < SIZE / 2 && Math.floor(i / SIZE) < SIZE / 2 ? 1 : 0,
);

/**
 * A stand-in for onnxruntime-node that records what the segmenter hands it.
 * `infer(feeds, callNumber)` answers each run.
 */
const fakeRuntime = ({
  inputNames = ["input.1"],
  outputNames = ["d0", "d1"],
  infer = () => ({ d0: { data: quadrant } }),
} = {}) => {
  const log = { created: [], feeds: [], tensors: [], released: 0 };
  class Tensor {
    constructor(type, data, dims) {
      Object.assign(this, { type, data, dims });
      log.tensors.push(this);
    }
  }
  const session = {
    inputNames,
    outputNames,
    run: async (feeds) => {
      log.feeds.push(feeds);
      return infer(feeds, log.feeds.length);
    },
    release: async () => {
      log.released += 1;
    },
  };
  const runtime = {
    Tensor,
    InferenceSession: {
      create: async (file, options) => {
        log.created.push({ file, options });
        return session;
      },
    },
  };
  return { log, session, runtime };
};

const open = async (options) => {
  const fake = fakeRuntime(options);
  const segmenter = await createSegmenter("/models/fake-net.onnx", SPEC, {
    runtime: fake.runtime,
  });
  return { ...fake, segmenter };
};

describe("createSegmenter session and tensor", () => {
  test("opens the model file on the CPU with full graph optimization", async () => {
    const { log, segmenter } = await open();
    assert.deepEqual(log.created, [
      {
        file: "/models/fake-net.onnx",
        options: { executionProviders: ["cpu"], graphOptimizationLevel: "all" },
      },
    ]);
    assert.equal(segmenter.model, "fake-net");
    assert.equal(typeof segmenter.segment, "function");
    assert.equal(typeof segmenter.dispose, "function");
    assert.equal(log.feeds.length, 0, "nothing runs until segment()");
  });

  test("feeds a float32 [1, 3, S, S] tensor under the first input name", async () => {
    const { log, segmenter } = await open({
      inputNames: ["pixel_values", "unused"],
      outputNames: ["logits", "aux"],
      infer: () => ({
        logits: { data: quadrant },
        aux: { data: new Float32Array(SIZE * SIZE).fill(-9) },
      }),
    });
    await segmenter.segment(image(37, 23, [60, 120, 240]));
    assert.equal(log.tensors.length, 1);
    assert.deepEqual(Object.keys(log.feeds[0]), ["pixel_values"]);
    const [tensor] = log.tensors;
    assert.equal(log.feeds[0].pixel_values, tensor);
    assert.equal(tensor.type, "float32");
    assert.deepEqual(tensor.dims, [1, 3, SIZE, SIZE]);
    assert.ok(tensor.data instanceof Float32Array);
    assert.equal(tensor.data.length, 3 * SIZE * SIZE);
  });

  test("normalizes the resized image, brightest value first", async () => {
    const { log, segmenter } = await open();
    await segmenter.segment(image(37, 23, [60, 120, 240]));
    const { data } = log.tensors[0];
    const plane = SIZE * SIZE;
    // The brightest sample (blue, 240) is the divisor for every channel.
    closeTo(data.subarray(0, plane), Array(plane).fill(0.25), 0.01);
    closeTo(data.subarray(plane, 2 * plane), Array(plane).fill(0.5), 0.01);
    closeTo(data.subarray(2 * plane), Array(plane).fill(1), 0.01);
  });

  test("keeps the image upright and in channel order in the tensor", async () => {
    const { log, segmenter } = await open();
    const bright = (x, y) => (x < 18 && y < 11 ? [255, 0, 0] : [0, 0, 0]);
    await segmenter.segment(image(37, 23, bright));
    const { data } = log.tensors[0];
    const plane = SIZE * SIZE;
    assert.ok(data[0] > 0.9, "top-left is bright");
    assert.ok(data[SIZE - 1] < 0.1, "top-right is dark");
    assert.ok(data[(SIZE - 1) * SIZE] < 0.1, "bottom-left is dark");
    assert.ok(data[plane - 1] < 0.1, "bottom-right is dark");
    assert.ok(
      data.subarray(plane).every((value) => value === 0),
      "only red",
    );
  });

  test("squeezes the whole picture into the square instead of cropping it", async () => {
    const { log, segmenter } = await open();
    await segmenter.segment(
      image(37, 23, (x) => (x >= 33 ? [255, 0, 0] : [0, 0, 0])),
    );
    const { data } = log.tensors[0];
    assert.ok(
      data[3 * SIZE + SIZE - 1] > 0.5,
      "the right-edge stripe survives",
    );
    assert.ok(data[3 * SIZE] < 0.1, "the left edge stays dark");
  });
});

describe("createSegmenter mask", () => {
  test("returns a 1-channel Uint8Array at the image's own size", async () => {
    const { segmenter } = await open();
    const mask = await segmenter.segment(image(37, 23, [90, 90, 90]));
    assert.ok(mask instanceof Uint8Array);
    assert.equal(mask.length, 37 * 23);
    assert.equal(mask.byteLength, 37 * 23);
    // A 3-channel resize read as one channel would stretch the top third of
    // the picture over every row and make the bottom corner bright.
    assert.ok(at(mask, 37, 1, 1) > 200, "top-left is subject");
    assert.ok(at(mask, 37, 35, 1) < 50, "top-right is background");
    assert.ok(at(mask, 37, 1, 21) < 50, "bottom-left is background");
    assert.ok(at(mask, 37, 35, 21) < 50, "bottom-right is background");
  });

  test("stretches the prediction over the whole image instead of cropping it", async () => {
    // Only the last prediction row is high; a cropped upscale would drop it.
    const bottom = Float32Array.from({ length: SIZE * SIZE }, (_, i) =>
      Math.floor(i / SIZE) === SIZE - 1 ? 1 : 0,
    );
    const { segmenter } = await open({
      infer: () => ({ d0: { data: bottom } }),
    });
    const mask = await segmenter.segment(image(37, 23, [4, 5, 6]));
    assert.ok(at(mask, 37, 18, 22) > 200, "last row is subject");
    assert.ok(at(mask, 37, 18, 1) < 50, "first row is background");
  });

  for (const [width, height] of [
    [1, 1],
    [1, 50],
    [50, 1],
    [8, 8],
    [200, 3],
    [5, 300],
  ]) {
    test(`keeps width * height bytes for a ${width}x${height} image`, async () => {
      const { segmenter } = await open();
      const mask = await segmenter.segment(image(width, height, [5, 6, 7]));
      assert.ok(mask instanceof Uint8Array);
      assert.equal(mask.length, width * height);
    });
  }

  test("turns a uniform prediction into a uniform mask", async () => {
    const flat = new Float32Array(SIZE * SIZE).fill(0.9);
    const { segmenter } = await open({ infer: () => ({ d0: { data: flat } }) });
    const mask = await segmenter.segment(image(37, 23, [1, 2, 3]));
    assert.equal(mask.length, 37 * 23);
    assert.ok(
      mask.every((value) => value === mask[0]),
      "one value everywhere",
    );
    assert.equal(mask[0], 0, "a constant prediction marks no subject");
  });

  test("uses the first S * S values of a longer output", async () => {
    const wild = new Float32Array(SIZE * SIZE).fill(1e6);
    const longer = Float32Array.from([...quadrant, ...wild]);
    const plainRun = await open();
    const longRun = await open({ infer: () => ({ d0: { data: longer } }) });
    const img = image(37, 23, [1, 2, 3]);
    const expected = await plainRun.segmenter.segment(img);
    assert.deepEqual(await longRun.segmenter.segment(img), expected);
  });
});

const until = async (condition, label) => {
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.fail(`timed out waiting for ${label}`);
};

describe("createSegmenter queue and failures", () => {
  const img = image(37, 23, [10, 20, 30]);

  test("runs one inference at a time, in call order", async () => {
    const gates = [];
    let active = 0;
    let peak = 0;
    const { segmenter } = await open({
      infer: async () => {
        active += 1;
        peak = Math.max(peak, active);
        await new Promise((release) => gates.push(release));
        active -= 1;
        return { d0: { data: quadrant } };
      },
    });
    const finished = [];
    const calls = ["first", "second", "third"].map((name) =>
      segmenter.segment(img).then(() => finished.push(name)),
    );
    await until(() => gates.length === 1, "the first run");
    // Give a wrongly parallel second run time to start.
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(gates.length, 1, "the second run must wait");
    for (let turn = 0; turn < 3; turn += 1) {
      await until(() => gates.length === turn + 1, `run ${turn + 1}`);
      gates[turn]();
    }
    await Promise.all(calls);
    assert.equal(peak, 1);
    assert.deepEqual(finished, ["first", "second", "third"]);
  });

  test("a failing run rejects that call but later calls still work", async () => {
    const { segmenter } = await open({
      infer: (feeds, call) => {
        if (call === 1) throw new Error("session blew up");
        return { d0: { data: quadrant } };
      },
    });
    const failing = segmenter.segment(img);
    const queued = segmenter.segment(img);
    await assert.rejects(failing, { message: "session blew up" });
    assert.equal((await queued).length, 37 * 23);
    assert.equal((await segmenter.segment(img)).length, 37 * 23);
  });

  test("rejects pixels that are not RGB without running the model", async () => {
    const { log, segmenter } = await open();
    for (const channels of [1, 2, 4]) {
      const data = Buffer.alloc(4 * 3 * channels);
      await assert.rejects(
        segmenter.segment({ data, width: 4, height: 3, channels }),
        /expects raw RGB pixels/,
      );
    }
    assert.equal(log.feeds.length, 0);
    assert.equal((await segmenter.segment(img)).length, 37 * 23);
  });

  test("rejects pixel data that is shorter than width * height * 3", async () => {
    const { log, segmenter } = await open();
    const data = Buffer.alloc(10 * 10 * 3 - 30);
    await assert.rejects(
      segmenter.segment({ data, width: 10, height: 10, channels: 3 }),
    );
    assert.equal(log.feeds.length, 0);
    assert.equal((await segmenter.segment(img)).length, 37 * 23);
  });

  test("rejects an output shorter than S * S, then recovers", async () => {
    const short = new Float32Array(SIZE * SIZE - 1);
    const { segmenter } = await open({
      infer: (feeds, call) => ({ d0: { data: call === 1 ? short : quadrant } }),
    });
    await assert.rejects(
      segmenter.segment(img),
      /fake-net returned an unexpected output shape/,
    );
    assert.equal((await segmenter.segment(img)).length, 37 * 23);
  });

  test("dispose releases the session", async () => {
    const { log, segmenter } = await open();
    await segmenter.dispose();
    assert.equal(log.released, 1);
  });

  test("dispose reports a failing release", async () => {
    const { session, segmenter } = await open();
    session.release = async () => {
      throw new Error("release failed");
    };
    await assert.rejects(segmenter.dispose(), { message: "release failed" });
  });
});

const MODEL_DIR = process.env.OSCARS_REMOVE_BG_MODELS;
const REAL_MODEL = MODEL_DIR ? path.join(MODEL_DIR, "u2netp.onnx") : "";
const REAL_SKIP =
  REAL_MODEL && existsSync(REAL_MODEL)
    ? false
    : "set OSCARS_REMOVE_BG_MODELS to a directory containing u2netp.onnx";

describe("createSegmenter with the real runtime", () => {
  test(
    "rates a bright disc above its dark background",
    { skip: REAL_SKIP },
    async () => {
      const [width, height, cx, cy, radius] = [64, 48, 32, 24, 14];
      const inside = (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2;
      const disc = image(width, height, (x, y) =>
        inside(x, y) ? [240, 240, 240] : [20, 20, 20],
      );
      const segmenter = await createSegmenter(REAL_MODEL, MODELS.u2netp);
      try {
        const mask = await segmenter.segment(disc);
        assert.ok(mask instanceof Uint8Array);
        assert.equal(mask.length, width * height);
        const sums = { subject: [0, 0], background: [0, 0] };
        for (let y = 0; y < height; y += 1) {
          for (let x = 0; x < width; x += 1) {
            const group = inside(x, y) ? sums.subject : sums.background;
            group[0] += mask[y * width + x];
            group[1] += 1;
          }
        }
        const mean = ([total, count]) => total / count;
        const subject = mean(sums.subject);
        const background = mean(sums.background);
        assert.ok(subject > background + 100, `${subject} vs ${background}`);
      } finally {
        await segmenter.dispose();
      }
    },
  );
});
