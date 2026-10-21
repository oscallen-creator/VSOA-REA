import { after, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { RECORDING_SAMPLE_RATE } from "../src/main/constants.js";
import { SPEECH_MODEL } from "../src/main/transcription/speechModel.js";
import {
  Transcriber,
  recognizerConfig,
} from "../src/main/transcription/transcriber.js";

const dirs = [];
const makeDir = async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "whisper-model-"));
  dirs.push(dir);
  return dir;
};
const makeModelDir = async () => {
  const dir = await makeDir();
  for (const file of Object.values(SPEECH_MODEL.files))
    await writeFile(path.join(dir, file), "");
  return dir;
};
after(() =>
  Promise.all(dirs.map((dir) => rm(dir, { recursive: true, force: true }))),
);

/**
 * A transcriber over a fake engine. `texts[i]` is what the i-th decoded stream returns, and the
 * first `createFailures` calls to `createAsync` reject.
 */
const setup = async ({ texts = [], createFailures = 0, modelDir } = {}) => {
  const state = { engineLoads: 0, configs: [], streams: [], maxInFlight: 0 };
  let inFlight = 0;
  const recognizer = {
    createStream: () => {
      const stream = {
        waveforms: [],
        acceptWaveform: (waveform) => stream.waveforms.push(waveform),
      };
      state.streams.push(stream);
      return stream;
    },
    decodeAsync: async (stream) => {
      state.maxInFlight = Math.max(state.maxInFlight, ++inFlight);
      await Promise.resolve();
      inFlight--;
      return { text: texts[state.streams.indexOf(stream)] };
    },
  };
  const engine = {
    OfflineRecognizer: {
      createAsync: async (config) => {
        state.configs.push(config);
        if (state.configs.length <= createFailures) throw new Error("boom");
        return recognizer;
      },
    },
  };
  const options = {
    modelDir: modelDir ?? (await makeModelDir()),
    numThreads: 2,
    loadEngine: async () => (state.engineLoads++, engine),
  };
  return { state, recognizer, options, transcriber: new Transcriber(options) };
};

const SECONDS = RECORDING_SAMPLE_RATE;
const audio = (seconds) => new Float32Array(seconds * SECONDS).fill(0.1);

describe("recognizerConfig", () => {
  test("points the transducer and tokens at files in the model directory", () => {
    const dir = path.join(os.tmpdir(), "some-model");
    const { transducer, tokens } = recognizerConfig(dir, 3).modelConfig;
    assert.deepEqual(transducer, {
      encoder: path.join(dir, SPEECH_MODEL.files.encoder),
      decoder: path.join(dir, SPEECH_MODEL.files.decoder),
      joiner: path.join(dir, SPEECH_MODEL.files.joiner),
    });
    assert.equal(tokens, path.join(dir, SPEECH_MODEL.files.tokens));
  });

  test("describes a 16 kHz, 80-dim CPU nemo transducer with the given threads", () => {
    const { featConfig, modelConfig } = recognizerConfig("model", 3);
    assert.deepEqual(featConfig, { sampleRate: 16_000, featureDim: 80 });
    assert.deepEqual(
      [modelConfig.modelType, modelConfig.provider, modelConfig.numThreads],
      ["nemo_transducer", "cpu", 3],
    );
  });
});

describe("Transcriber.load", () => {
  test("creates the recognizer once for repeated and concurrent calls", async () => {
    const h = await setup();
    const [first, second] = await Promise.all([
      h.transcriber.load(),
      h.transcriber.load(),
    ]);
    assert.equal(first, h.recognizer);
    assert.equal(second, h.recognizer);
    assert.equal(await h.transcriber.load(), h.recognizer);
    assert.deepEqual([h.state.engineLoads, h.state.configs.length], [1, 1]);
  });

  test("gives the engine the config for its model directory and threads", async () => {
    const h = await setup();
    await h.transcriber.load();
    assert.deepEqual(h.state.configs, [
      recognizerConfig(h.options.modelDir, h.options.numThreads),
    ]);
  });

  test("defaults to between one and four threads", async () => {
    const h = await setup();
    const transcriber = new Transcriber({
      modelDir: h.options.modelDir,
      loadEngine: h.options.loadEngine,
    });
    await transcriber.load();
    const { numThreads } = h.state.configs[0].modelConfig;
    assert.ok(
      Number.isInteger(numThreads) && numThreads >= 1 && numThreads <= 4,
    );
  });

  test("rejects naming every missing model file, without loading the engine", async () => {
    const h = await setup({ modelDir: await makeDir() });
    const error = await h.transcriber.load().catch((caught) => caught);
    assert.match(error.message, /Speech model not found/);
    for (const file of Object.values(SPEECH_MODEL.files))
      assert.ok(error.message.includes(path.join(h.options.modelDir, file)));
    assert.deepEqual([h.state.engineLoads, h.state.configs.length], [0, 0]);
  });

  test("names only the files that are missing", async () => {
    const dir = await makeModelDir();
    await rm(path.join(dir, SPEECH_MODEL.files.joiner));
    const h = await setup({ modelDir: dir });
    const error = await h.transcriber.load().catch((caught) => caught);
    assert.ok(
      error.message.includes(path.join(dir, SPEECH_MODEL.files.joiner)),
    );
    assert.ok(!error.message.includes(SPEECH_MODEL.files.encoder));
    assert.equal(h.state.engineLoads, 0);
  });

  test("retries after the missing files appear", async () => {
    const dir = await makeDir();
    const h = await setup({ modelDir: dir });
    await assert.rejects(h.transcriber.load(), /Speech model not found/);
    for (const file of Object.values(SPEECH_MODEL.files))
      await writeFile(path.join(dir, file), "");
    assert.equal(await h.transcriber.load(), h.recognizer);
  });

  test("retries after the engine fails to create the recognizer", async () => {
    const h = await setup({ createFailures: 1 });
    await assert.rejects(h.transcriber.load(), /boom/);
    assert.equal(await h.transcriber.load(), h.recognizer);
    assert.equal(h.state.configs.length, 2);
  });

  test("shares one failed attempt between concurrent callers", async () => {
    const h = await setup({ createFailures: 1 });
    const results = await Promise.allSettled([
      h.transcriber.load(),
      h.transcriber.load(),
    ]);
    assert.deepEqual(
      results.map((result) => result.status),
      ["rejected", "rejected"],
    );
    assert.equal(h.state.configs.length, 1);
  });
});

describe("Transcriber.transcribe", () => {
  test("hands float samples at 16 kHz to the stream and returns the trimmed text", async () => {
    const h = await setup({ texts: ["  hello world \n"] });
    const samples = new Float32Array(8_000).fill(0.25);
    assert.equal(await h.transcriber.transcribe(samples), "hello world");
    assert.equal(h.state.streams.length, 1);
    assert.deepEqual(h.state.streams[0].waveforms, [
      { samples, sampleRate: 16_000 },
    ]);
    assert.ok(h.state.streams[0].waveforms[0].samples instanceof Float32Array);
  });

  test("returns nothing for input under half a second, without loading the model", async () => {
    const h = await setup({ texts: ["Yeah."] });
    assert.equal(await h.transcriber.transcribe(new Float32Array(7_999)), "");
    assert.equal(await h.transcriber.transcribe(new Float32Array(0)), "");
    assert.deepEqual([h.state.engineLoads, h.state.streams.length], [0, 0]);
  });

  test("retries a failed load on the next transcription", async () => {
    const h = await setup({ createFailures: 1, texts: ["second try"] });
    await assert.rejects(h.transcriber.transcribe(audio(1)), /boom/);
    assert.equal(await h.transcriber.transcribe(audio(1)), "second try");
  });

  test("rejects with the missing-model error", async () => {
    const h = await setup({ modelDir: await makeDir() });
    await assert.rejects(
      h.transcriber.transcribe(audio(1)),
      /Speech model not found/,
    );
    assert.equal(h.state.streams.length, 0);
  });

  test("decodes long input in several streams, in order, and joins the texts", async () => {
    const h = await setup({
      texts: ["first part.", "second part.", "third part."],
    });
    const samples = audio(70);
    assert.equal(
      await h.transcriber.transcribe(samples),
      "first part. second part. third part.",
    );
    assert.equal(h.state.streams.length, 3);
    assert.equal(h.state.maxInFlight, 1);
    const waveforms = h.state.streams.flatMap((stream) => stream.waveforms);
    assert.ok(waveforms.every(({ sampleRate }) => sampleRate === 16_000));
    assert.equal(
      waveforms.reduce((sum, { samples: chunk }) => sum + chunk.length, 0),
      samples.length,
    );
  });

  test("trims each text and skips empty or whitespace-only ones", async () => {
    const h = await setup({ texts: ["  hello there  ", "   ", " world\n"] });
    assert.equal(
      await h.transcriber.transcribe(audio(70)),
      "hello there world",
    );
  });

  test("skips streams that return no text at all", async () => {
    const h = await setup({ texts: ["a", undefined, "b"] });
    assert.equal(await h.transcriber.transcribe(audio(70)), "a b");
  });

  test("returns an empty string when nothing was recognized", async () => {
    const long = await setup({ texts: ["", "  ", undefined] });
    assert.equal(await long.transcriber.transcribe(audio(70)), "");
    const short = await setup({ texts: ["\n"] });
    assert.equal(await short.transcriber.transcribe(audio(1)), "");
  });
});
