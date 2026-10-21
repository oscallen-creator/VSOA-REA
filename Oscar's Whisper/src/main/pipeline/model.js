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
 * Optional model pass over the locally cleaned transcript (punctuation, grammar, formatting).
 * @param {string} text
 * @param {{apiKey: string, cleanupModel: string}} config
 * @returns {Promise<string>}
 */
export const cleanupWithModel = async (text, config) => {
  if (config.apiKey) {
    // TODO(api-key): send `text` to your language model using `config.apiKey` and
    // `config.cleanupModel` with an instruction to fix punctuation and remove disfluencies
    // without changing meaning, and return its reply.
  }
  return text;
};
