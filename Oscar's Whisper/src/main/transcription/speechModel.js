// The speech-to-text model shipped inside the app: NVIDIA Parakeet TDT 0.6B v2 (English,
// CC-BY-4.0), int8-quantized and exported for sherpa-onnx by its authors. It is downloaded at
// build time by scripts/fetch-model.mjs into models/<id>/ and is never committed.

import path from "node:path";

export const SPEECH_MODEL = Object.freeze({
  id: "parakeet-tdt-0.6b-v2-int8",
  archiveUrl:
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
  archiveSha256:
    "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad",
  archiveBytes: 482_468_385,
  /** Files the recognizer needs, relative to the model directory. */
  files: Object.freeze({
    encoder: "encoder.int8.onnx",
    decoder: "decoder.int8.onnx",
    joiner: "joiner.int8.onnx",
    tokens: "tokens.txt",
  }),
  /** A short English recording that comes with the model; used by tests, not shipped. */
  sampleWav: "test_wavs/0.wav",
  /** Shorter input makes the model invent words ("Yeah.", "Mm-hmm."), even from silence. */
  minInputSeconds: 0.5,
});

export const modelFiles = (modelDir) =>
  Object.fromEntries(
    Object.entries(SPEECH_MODEL.files).map(([role, file]) => [
      role,
      path.join(modelDir, file),
    ]),
  );
