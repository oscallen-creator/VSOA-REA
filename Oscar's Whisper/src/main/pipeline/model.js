// The one place that talks to a hosted AI model. Both calls are placeholders for now:
// they keep the real call signatures so the rest of the app is already wired, and they
// return stand-in results until an API key and provider request are added here.

const simulateLatency = (ms) =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Speech-to-text ("ingestion").
 * @param {{wav: Buffer, sampleRate: number, durationMs: number}} audio 16-bit mono WAV
 * @param {{apiKey: string, transcriptionModel: string}} config
 * @returns {Promise<string>} raw transcript
 */
export const transcribe = async (audio, config) => {
  if (config.apiKey) {
    // TODO(api-key): send `audio.wav` (audio/wav) to your speech-to-text provider using
    // `config.apiKey` and `config.transcriptionModel`, and return the transcript text.
  }
  await simulateLatency(250);
  const seconds = (audio.durationMs / 1000).toFixed(1);
  return `um this is a placeholder transcript of ${seconds} seconds of audio`;
};

/**
 * The main cleanup step: a language model rewrites the raw transcript (punctuation,
 * capitalization, filler words, false starts), like Wispr's server-side "format" stage.
 * @param {string} rawTranscript
 * @param {{apiKey: string, cleanupModel: string}} config
 * @returns {Promise<string | null>} formatted text, or null when no model is connected,
 *   in which case the pipeline falls back to the local cleanup rules.
 */
export const cleanupWithModel = async (rawTranscript, config) => {
  if (config.apiKey) {
    // TODO(api-key): send `rawTranscript` to your language model using `config.apiKey` and
    // `config.cleanupModel`, with an instruction to fix punctuation and remove disfluencies
    // without changing meaning, and return its reply.
  }
  return null;
};
