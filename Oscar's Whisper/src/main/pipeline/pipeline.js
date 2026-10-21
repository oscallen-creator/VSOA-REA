// One finished recording: PCM -> WAV -> transcript -> cleaned text -> pasted into the focused app.

import { pcmDurationMs, encodeWav } from "../audio/wav.js";
import { RECORDING_SAMPLE_RATE } from "../constants.js";
import { cleanupTranscript } from "./cleanup.js";
import { cleanupWithModel, transcribe } from "./model.js";
import { pasteText } from "./paste.js";

/** Recordings shorter than this are treated as empty. */
const MIN_AUDIO_MS = 200;

export const createPipeline = ({ config, paste = pasteText }) => {
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
      const text = await cleanupWithModel(cleanupTranscript(raw), config);
      if (!text) return { pasted: false, reason: "empty_transcript" };
      lastText = text;
      await paste(text, config);
      return { pasted: true, text };
    },
  };
};
