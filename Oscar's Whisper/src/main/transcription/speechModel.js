// The speech-to-text model shipped inside the app: NVIDIA Parakeet TDT 0.6B v2 (English,
// CC-BY-4.0), int8-quantized and exported for sherpa-onnx by its authors. It is downloaded at
// build time by scripts/fetch-model.mjs into models/<id>/ and is never committed.

import path from "node:path";

export const SPEECH_MODEL = Object.freeze({
  id: "parakeet-tdt-0.6b-v2-int8",
  /**
   * One Hugging Face commit (2025-08-16) of the sherpa-onnx export. A commit never changes, so
   * every build gets these exact bytes. The sherpa-onnx GitHub release archive is not used: it
   * was re-exported on 2026-11-07 with different files.
   */
  baseUrl:
    "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/1ab9323565ddb038682214b292f588070a538ce2",
  /** SHA-256 of every file fetch-model downloads (661 MB in all). */
  sha256: Object.freeze({
    "encoder.int8.onnx":
      "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab",
    "decoder.int8.onnx":
      "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e",
    "joiner.int8.onnx":
      "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2",
    "tokens.txt":
      "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d",
    "test_wavs/0.wav":
      "5fceacff0315d49cb59fcc505bcecf1ed5f2f35c2897b1e65a59f30e5d922150",
  }),
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
