// Local speech-to-text with the bundled Parakeet model, run by sherpa-onnx. Nothing leaves the
// computer. The model (about 650 MB) loads once, in the background, when the app starts; a
// dictation that finishes before then waits for it. Loading and decoding run on native worker
// threads, so the key hook and the bar stay responsive meanwhile.

import { access } from "node:fs/promises";
import os from "node:os";
import { RECORDING_SAMPLE_RATE } from "../constants.js";
import { splitAtQuietPoints } from "./chunking.js";
import { modelFiles, SPEECH_MODEL } from "./speechModel.js";

/** Leave a core free for the rest of the system; more than 4 threads barely helps. */
const defaultThreads = () =>
  Math.max(1, Math.min(4, os.availableParallelism() - 1));

/** Loaded on first use, so a missing native build shows up as a dictation error, not a crash. */
const loadSherpa = async () => (await import("sherpa-onnx-node")).default;

const MIN_INPUT_SAMPLES = Math.round(
  SPEECH_MODEL.minInputSeconds * RECORDING_SAMPLE_RATE,
);

export const recognizerConfig = (modelDir, numThreads) => {
  const { encoder, decoder, joiner, tokens } = modelFiles(modelDir);
  return {
    featConfig: { sampleRate: RECORDING_SAMPLE_RATE, featureDim: 80 },
    modelConfig: {
      transducer: { encoder, decoder, joiner },
      tokens,
      numThreads,
      provider: "cpu",
      debug: 0,
      modelType: "nemo_transducer",
    },
    decodingMethod: "greedy_search",
  };
};

export class Transcriber {
  #modelDir;
  #numThreads;
  #loadEngine;
  #loading = null;

  /**
   * @param {{modelDir: string, numThreads?: number, loadEngine?: () => Promise<any>}} options
   */
  constructor({
    modelDir,
    numThreads = defaultThreads(),
    loadEngine = loadSherpa,
  }) {
    this.#modelDir = modelDir;
    this.#numThreads = numThreads;
    this.#loadEngine = loadEngine;
  }

  /** Loads the model once; a failed load is retried by the next call. */
  load() {
    this.#loading ??= this.#createRecognizer().catch((error) => {
      this.#loading = null;
      throw error;
    });
    return this.#loading;
  }

  /**
   * @param {Float32Array} samples 16 kHz mono in [-1, 1]
   * @returns {Promise<string>} the transcript; "" when no speech was recognized
   */
  async transcribe(samples) {
    if (samples.length < MIN_INPUT_SAMPLES) return "";
    const recognizer = await this.load();
    const parts = [];
    for (const chunk of splitAtQuietPoints(samples, RECORDING_SAMPLE_RATE)) {
      const stream = recognizer.createStream();
      stream.acceptWaveform({
        samples: chunk,
        sampleRate: RECORDING_SAMPLE_RATE,
      });
      const { text } = await recognizer.decodeAsync(stream);
      if (text?.trim()) parts.push(text.trim());
    }
    return parts.join(" ");
  }

  async #createRecognizer() {
    const config = recognizerConfig(this.#modelDir, this.#numThreads);
    const files = [
      ...Object.values(config.modelConfig.transducer),
      config.modelConfig.tokens,
    ];
    const missing = [];
    for (const file of files)
      await access(file).catch(() => missing.push(file));
    if (missing.length > 0) {
      throw new Error(
        `Speech model not found (${missing.join(", ")}). Run "npm run fetch-model".`,
      );
    }
    const { OfflineRecognizer } = await this.#loadEngine();
    return OfflineRecognizer.createAsync(config);
  }
}
