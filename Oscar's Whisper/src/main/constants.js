// Timing and audio parameters, matched to the values recovered from Wispr Flow 1.6.1209.

/** A second press within this window locks hands-free mode; a shorter hold is an accidental tap. */
export const DICTATION_DEBOUNCE_DELAY_MS = 500;

/** Hard stop for one dictation, with a warning one minute earlier. */
export const DICTATION_DURATION_TIMEOUT_MS = 20 * 60_000;
export const DICTATION_DURATION_WARNING_MS = 19 * 60_000;

/** Mono 16 kHz capture, delivered in 640-sample (40 ms) chunks. */
export const RECORDING_SAMPLE_RATE = 16_000;
export const RECORDER_CHUNK_SAMPLES = 640;

/** Keys held without any further event for this long are treated as stuck (missed key-up). */
export const STALE_KEY_MS = 60_000;
export const STALE_KEY_SWEEP_MS = 5_000;
