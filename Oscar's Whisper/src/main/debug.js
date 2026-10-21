// Opt-in diagnostics: set OSCARS_WHISPER_DEBUG=1. Never pass transcript or clipboard text here.
const enabled = Boolean(process.env.OSCARS_WHISPER_DEBUG);

export const debug = (...args) => {
  if (enabled) console.log("[oscars-whisper:debug]", ...args);
};
