import { before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { RECORDING_SAMPLE_RATE } from "../src/main/constants.js";
import { SPEECH_MODEL } from "../src/main/transcription/speechModel.js";
import { Transcriber } from "../src/main/transcription/transcriber.js";

const appDir = fileURLToPath(new URL("../", import.meta.url));
const modelDir = path.join(appDir, "models", SPEECH_MODEL.id);
const modelPresent = existsSync(
  path.join(modelDir, SPEECH_MODEL.files.encoder),
);

const words = (text) =>
  text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, "")
    .replace(/\s+/g, " ")
    .trim();

describe(
  "Transcriber with the real Parakeet model",
  {
    timeout: 120_000,
    skip: modelPresent
      ? false
      : `speech model not downloaded (missing ${SPEECH_MODEL.files.encoder}); run "npm run fetch-model"`,
  },
  () => {
    let transcriber;
    before(async () => {
      transcriber = new Transcriber({ modelDir });
      await transcriber.load();
    });

    test("transcribes the sample recording", async () => {
      const { readWave } = createRequire(path.join(appDir, "package.json"))(
        "sherpa-onnx-node",
      );
      const wave = readWave(path.join(modelDir, SPEECH_MODEL.sampleWav));
      assert.equal(wave.sampleRate, RECORDING_SAMPLE_RATE);
      const transcript = words(await transcriber.transcribe(wave.samples));
      assert.ok(
        transcript.includes(words("i don't wish to see it any more")),
        transcript,
      );
      assert.ok(
        transcript.includes(words("very like the old portrait")),
        transcript,
      );
    });

    test("returns an empty transcript for silence", async () => {
      const silence = new Float32Array(2 * RECORDING_SAMPLE_RATE);
      assert.equal(await transcriber.transcribe(silence), "");
    });
  },
);
