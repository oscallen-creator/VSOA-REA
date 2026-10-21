// One finished recording: PCM -> WAV -> transcript -> cleaned text -> pasted into the focused app.

import { pcmDurationMs, encodeWav } from "../audio/wav.js";
import { RECORDING_SAMPLE_RATE } from "../constants.js";
import { cleanupTranscript } from "./cleanup.js";
import { cleanupWithModel, transcribe } from "./model.js";
import { pasteText } from "./paste.js";

/** Recordings shorter than this are treated as empty. */
const MIN_AUDIO_MS = 200;

export const createPipeline = ({
  config,
  paste = pasteText,
  isModifierHeld = () => false,
}) => {
  let lastText = "";
  return {
    get lastText() {
      return lastText;
    },
    async run(pcm) {
      const durationMs = pcmDurationMs(pcm, RECORDING_SAMPLE_RATE);
      if (durationMs < MIN_AUDIO_MS)
        return { pasted: false, reason: "no_audio" };
      const wav = encodeWav(pcm, RECORDING_SAMPLE_RATE);
      const raw = await transcribe(
        { wav, sampleRate: RECORDING_SAMPLE_RATE, durationMs },
        config,
      );
      // As in Wispr: use the model's formatted text when there is one; the local rules are
      // only the fallback for a raw transcript.
      const formatted = await cleanupWithModel(raw, config);
      const text = formatted?.trim() || cleanupTranscript(raw);
      if (!text) return { pasted: false, reason: "empty_transcript" };
      lastText = text;
      // Wispr adds a trailing space when nothing follows the cursor, so consecutive
      // dictations don't run together. Without its accessibility helper this app cannot
      // read the text around the cursor, so it always applies that end-of-text rule.
      const result = await paste(`${text} `, config, { isModifierHeld });
      if (!result.pasted) {
        throw new Error(
          `Paste failed (${result.error}); the text is on the clipboard`,
        );
      }
      return { pasted: true, text };
    },
  };
};
