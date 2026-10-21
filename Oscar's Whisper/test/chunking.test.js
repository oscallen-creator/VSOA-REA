import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  MAX_CHUNK_SECONDS,
  splitAtQuietPoints,
} from "../src/main/transcription/chunking.js";

const RATE = 16_000;
const LIMIT = MAX_CHUNK_SECONDS * RATE;
const SEARCH = 5 * RATE;
const HALF_WINDOW = 800; // half of the 100 ms comparison window

/** Deterministic loud audio, never exactly zero. */
const noise = (length, seed = 1) => {
  const samples = new Float32Array(length);
  let state = seed;
  for (let i = 0; i < length; i++) {
    state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
    samples[i] = 0.1 + 0.4 * (state / 2 ** 32);
  }
  return samples;
};

const fill = (samples, from, to, value = 0) => samples.fill(value, from, to);

/** Pieces must be non-empty views of `samples` that follow one another exactly. */
const assertTiles = (chunks, samples, max) => {
  let end = 0;
  for (const chunk of chunks) {
    assert.equal(chunk.buffer, samples.buffer);
    assert.equal(chunk.byteOffset - samples.byteOffset, end * 4);
    assert.ok(
      chunk.length > 0 && chunk.length <= max,
      `length ${chunk.length}`,
    );
    end += chunk.length;
  }
  assert.equal(end, samples.length);
};

const cutsOf = (chunks) =>
  chunks
    .slice(0, -1)
    .map((_, i) =>
      chunks.slice(0, i + 1).reduce((sum, chunk) => sum + chunk.length, 0),
    );

describe("splitAtQuietPoints pieces", () => {
  test("returns the same array when it fits in one piece", () => {
    const samples = noise(10 * RATE);
    const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.equal(chunks.length, 1);
    assert.equal(chunks[0], samples);
  });

  test("does not split empty input or input of exactly the limit", () => {
    for (const length of [0, LIMIT]) {
      const samples = noise(length);
      const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
      assert.equal(chunks.length, 1);
      assert.equal(chunks[0], samples);
    }
  });

  test("splits as soon as the input is one sample over the limit", () => {
    const samples = noise(LIMIT + 1);
    const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.equal(chunks.length, 2);
    assertTiles(chunks, samples, LIMIT);
  });

  test("defaults to the 30 second limit", () => {
    assert.equal(MAX_CHUNK_SECONDS, 30);
    const samples = noise(31 * RATE);
    const chunks = splitAtQuietPoints(samples, RATE);
    assert.equal(chunks.length, 2);
    assertTiles(chunks, samples, LIMIT);
  });

  test("covers long input exactly, in order, within the limit", () => {
    const samples = noise(95 * RATE);
    const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.equal(chunks.length, 4);
    assertTiles(chunks, samples, LIMIT);
  });

  test("cuts every piece but the last within five seconds of the limit", () => {
    const chunks = splitAtQuietPoints(noise(95 * RATE), RATE, {
      maxSeconds: 30,
    });
    for (const chunk of chunks.slice(0, -1)) {
      assert.ok(chunk.length >= LIMIT - SEARCH && chunk.length <= LIMIT);
    }
  });
});

describe("splitAtQuietPoints last piece", () => {
  test("keeps the last piece at least one second long when the input barely exceeds the limit", () => {
    const rate = 1_000;
    for (const extra of [1, 10, 500, 999]) {
      const samples = new Float32Array(30 * rate + extra).fill(0.5);
      samples.fill(0, 30 * rate - 50, 30 * rate + extra);
      const pieces = splitAtQuietPoints(samples, rate);
      assert.ok(pieces.length >= 2);
      assert.ok(pieces.at(-1).length >= rate, `extra=${extra}`);
      assert.equal(
        pieces.reduce((total, piece) => total + piece.length, 0),
        samples.length,
      );
    }
  });
});

describe("splitAtQuietPoints cut placement", () => {
  test("cuts inside a silent gap shortly before the limit", () => {
    const samples = noise(40 * RATE);
    const gap = [LIMIT - 2 * RATE, LIMIT - 2 * RATE + 0.3 * RATE];
    fill(samples, ...gap);
    const [first] = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.ok(first.length >= gap[0] && first.length <= gap[1]);
  });

  test("cuts at the centre of the quietest 100 ms window", () => {
    const samples = noise(40 * RATE);
    const from = LIMIT - SEARCH + 60 * HALF_WINDOW; // on the 50 ms hop grid
    fill(samples, from, from + 2 * HALF_WINDOW);
    const [first] = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.equal(first.length, from + HALF_WINDOW);
  });

  test("prefers the quietest moment over an earlier, merely quiet one", () => {
    const samples = noise(40 * RATE);
    fill(samples, LIMIT - 4 * RATE, LIMIT - 3 * RATE, 0.01);
    fill(samples, LIMIT - 2 * RATE, LIMIT - 1.5 * RATE);
    const [first] = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.ok(first.length >= LIMIT - 2 * RATE);
    assert.ok(first.length <= LIMIT - 1.5 * RATE);
  });

  test("ignores silence outside the last five seconds before the limit", () => {
    const samples = noise(40 * RATE);
    fill(samples, 10 * RATE, 11 * RATE);
    fill(samples, LIMIT + RATE, LIMIT + 2 * RATE);
    const [first] = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assert.ok(first.length >= LIMIT - SEARCH && first.length <= LIMIT);
  });

  test("searches again from each cut", () => {
    const samples = noise(60 * RATE);
    const gaps = [
      [LIMIT - 2 * RATE, LIMIT - 2 * RATE + 0.3 * RATE],
      [900_000, 904_800], // inside the second search range wherever the first cut fell
    ];
    for (const gap of gaps) fill(samples, ...gap);
    const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
    assertTiles(chunks, samples, LIMIT);
    const cuts = cutsOf(chunks);
    assert.equal(cuts.length, 2);
    gaps.forEach(([from, to], i) => {
      assert.ok(cuts[i] >= from && cuts[i] <= to, `cut ${cuts[i]}`);
    });
  });
});

describe("splitAtQuietPoints degenerate input", () => {
  test("still makes progress and covers everything when no moment is quieter", () => {
    for (const level of [0.25, 0]) {
      const samples = new Float32Array(100 * RATE).fill(level);
      const chunks = splitAtQuietPoints(samples, RATE, { maxSeconds: 30 });
      assertTiles(chunks, samples, LIMIT);
    }
  });

  test("terminates when the search range would not fit in the piece", () => {
    const cases = [
      { rate: 10, maxSeconds: 1, length: 95 },
      { rate: 1, maxSeconds: 1, length: 7 },
      { rate: 10, maxSeconds: 0.5, length: 33 },
      { rate: 100, maxSeconds: 0.3, length: 1_000 },
    ];
    for (const { rate, maxSeconds, length } of cases) {
      const samples = noise(length);
      const chunks = splitAtQuietPoints(samples, rate, { maxSeconds });
      assertTiles(chunks, samples, Math.round(maxSeconds * rate));
    }
  });

  test("terminates with one-sample pieces when the limit rounds to zero samples", () => {
    class GuardedSamples extends Float32Array {
      calls = 0;
      subarray(...args) {
        if (++this.calls > 1_000)
          throw new Error("no progress after 1000 pieces");
        return super.subarray(...args);
      }
    }
    for (const [rate, maxSeconds] of [
      [10, 0.04],
      [RATE, 0],
    ]) {
      const samples = new GuardedSamples(20);
      const chunks = splitAtQuietPoints(samples, rate, { maxSeconds });
      assert.equal(chunks.length, samples.length);
      assertTiles(chunks, samples, 1);
    }
  });
});
