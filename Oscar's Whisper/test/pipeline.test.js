import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { createPipeline } from "../src/main/pipeline/pipeline.js";

const pcmOf = (ms) => Buffer.alloc((ms * 16 * 2) | 0, 1);
const setup = ({ transcript = "hi", pasteResult = { pasted: true } } = {}) => {
  const calls = { transcribe: [], paste: [] };
  const config = { pasteDelayMs: 1 };
  const isModifierHeld = () => false;
  const transcriber = {
    transcribe: async (samples) => (calls.transcribe.push(samples), transcript),
  };
  const paste = async (...args) => (calls.paste.push(args), pasteResult);
  return {
    calls,
    config,
    isModifierHeld,
    pipeline: createPipeline({ config, transcriber, paste, isModifierHeld }),
  };
};

describe("createPipeline", () => {
  test("treats under 200 ms of audio as no audio, without transcribing", async () => {
    const h = setup();
    assert.deepEqual(await h.pipeline.run(pcmOf(199)), {
      pasted: false,
      reason: "no_audio",
    });
    assert.deepEqual(await h.pipeline.run(Buffer.alloc(0)), {
      pasted: false,
      reason: "no_audio",
    });
    assert.deepEqual([h.calls.transcribe.length, h.calls.paste.length], [0, 0]);
  });

  test("transcribes exactly 200 ms of audio as Float32 samples", async () => {
    const h = setup();
    await h.pipeline.run(pcmOf(200));
    assert.equal(h.calls.transcribe.length, 1);
    assert.ok(h.calls.transcribe[0] instanceof Float32Array);
    assert.equal(h.calls.transcribe[0].length, 3200);
  });

  test("tidies the transcript and pastes it with a trailing space", async () => {
    const h = setup({ transcript: "um hello world" });
    assert.deepEqual(await h.pipeline.run(pcmOf(500)), {
      pasted: true,
      text: "Hello world",
    });
    assert.equal(h.calls.paste.length, 1);
    const [text, config, options] = h.calls.paste[0];
    assert.equal(text, "Hello world ");
    assert.equal(config, h.config);
    assert.deepEqual(options, { isModifierHeld: h.isModifierHeld });
    assert.equal(options.isModifierHeld, h.isModifierHeld);
  });

  test("pastes no trailing space after a spoken new line", async () => {
    const h = setup({ transcript: "Dear team new line" });
    await h.pipeline.run(pcmOf(500));
    assert.equal(h.calls.paste[0][0], "Dear team\n");
  });

  test("reports no speech for empty or filler-only transcripts, without pasting", async () => {
    for (const transcript of ["", "   ", "uh", "Um."]) {
      const h = setup({ transcript });
      const result = await h.pipeline.run(pcmOf(500));
      assert.deepEqual(result, { pasted: false, reason: "no_speech" });
      assert.equal(h.calls.paste.length, 0);
    }
  });

  test("throws when the paste fails, saying the text is on the clipboard", async () => {
    const h = setup({ pasteResult: { pasted: false, error: "no keystroke" } });
    await assert.rejects(h.pipeline.run(pcmOf(500)), (error) => {
      assert.ok(error instanceof Error);
      assert.match(error.message, /the text is on the clipboard/);
      assert.match(error.message, /no keystroke/);
      return true;
    });
  });

  test("propagates a transcriber rejection without pasting", async () => {
    const calls = [];
    const pipeline = createPipeline({
      config: {},
      transcriber: {
        transcribe: async () => {
          throw new Error("engine down");
        },
      },
      paste: async (...args) => (calls.push(args), { pasted: true }),
    });
    await assert.rejects(pipeline.run(pcmOf(500)), /engine down/);
    assert.equal(calls.length, 0);
  });
});
