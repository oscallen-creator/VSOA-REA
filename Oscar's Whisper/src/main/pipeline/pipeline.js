// One finished recording: PCM -> local speech-to-text -> local tidy-up -> pasted into the
// focused app.

import { pcm16ToFloat32 } from "../audio/pcm.js";
import { RECORDING_SAMPLE_RATE } from "../constants.js";
import { cleanupTranscript } from "./cleanup.js";

/** Recordings shorter than this are treated as empty. */
const MIN_AUDIO_MS = 200;

/**
 * @param {{config: object, transcriber: {transcribe(samples: Float32Array): Promise<string>},
 *   paste: typeof import("./paste.js").pasteText, isModifierHeld?: () => boolean}} deps
 */
export const createPipeline = ({
  config,
  transcriber,
  paste,
  isModifierHeld = () => false,
}) => ({
  async run(pcm) {
    const samples = pcm16ToFloat32(pcm);
    if ((samples.length / RECORDING_SAMPLE_RATE) * 1000 < MIN_AUDIO_MS)
      return { pasted: false, reason: "no_audio" };
    const text = cleanupTranscript(await transcriber.transcribe(samples));
    if (!text) return { pasted: false, reason: "no_speech" };
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
});
