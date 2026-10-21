// Long recordings are transcribed in pieces. Parakeet attends over the whole input at once, so
// time and memory grow faster than the audio's length; short pieces keep both small. Pieces are
// cut at the quietest moment near the limit, so a cut rarely lands inside a word.

/**
 * Longest piece decoded at once. Measured on Linux: 30-60 s pieces decode fastest per second of
 * audio, and past about 165 s in one piece Parakeet stops adding capitals and punctuation.
 */
export const MAX_CHUNK_SECONDS = 30;
/** The last piece is kept at least this long, because the model invents words for tiny input. */
const MIN_PIECE_SECONDS = 1;
/** How far back from the limit to look for a quiet moment. */
const SEARCH_SECONDS = 5;
/** Loudness is compared over windows this long, moved half a window at a time. */
const WINDOW_MS = 100;

const quietestPoint = (samples, from, to, window) => {
  const hop = Math.max(1, Math.floor(window / 2));
  let best = to;
  let bestEnergy = Infinity;
  for (let at = from; at + window <= to; at += hop) {
    let energy = 0;
    for (let i = at; i < at + window; i++) energy += samples[i] * samples[i];
    if (energy < bestEnergy) {
      bestEnergy = energy;
      best = at + Math.floor(window / 2);
    }
  }
  return best;
};

/**
 * @param {Float32Array} samples
 * @param {number} sampleRate
 * @returns {Float32Array[]} views into `samples`, in order, covering all of it
 */
export const splitAtQuietPoints = (
  samples,
  sampleRate,
  { maxSeconds = MAX_CHUNK_SECONDS, minPieceSeconds = MIN_PIECE_SECONDS } = {},
) => {
  // At least one sample per piece, so every cut moves forward.
  const max = Math.max(1, Math.round(maxSeconds * sampleRate));
  if (samples.length <= max) return [samples];
  const window = Math.max(1, Math.round((sampleRate * WINDOW_MS) / 1000));
  const search = Math.min(Math.round(SEARCH_SECONDS * sampleRate), max - 1);
  const minTail = Math.min(
    Math.round(minPieceSeconds * sampleRate),
    Math.floor(max / 2),
  );
  const chunks = [];
  let start = 0;
  while (samples.length - start > max) {
    const to = Math.min(start + max, samples.length - minTail);
    const from = Math.max(start + 1, Math.min(start + max - search, to));
    const cut = quietestPoint(samples, from, to, window);
    chunks.push(samples.subarray(start, cut));
    start = cut;
  }
  chunks.push(samples.subarray(start));
  return chunks;
};
