// Converts per-chunk RMS into a 0..1 level for the bar's waveform, the way Wispr does:
// dB per chunk, scaled against an adaptive noise floor (which only ever moves down),
// and averaged into one update every 150 ms.

export const LEVEL_UPDATE_MS = 150;
const INITIAL_FLOOR_DB = -60;
const RANGE_DB = 20;

export const rmsToDb = (rms) => 20 * Math.log10(rms + 1e-10);

export class LevelMeter {
  #floorDb = INITIAL_FLOOR_DB;
  #pending = [];

  /** Records one chunk; returns its scaled level. */
  push(rms) {
    const db = rmsToDb(rms);
    this.#floorDb = Math.min(this.#floorDb, db);
    const level = Math.max(0, Math.min(1, (db - this.#floorDb) / RANGE_DB));
    this.#pending.push(level);
    return level;
  }

  /** Mean of the levels since the last call, or null when nothing arrived. */
  drain() {
    if (this.#pending.length === 0) return null;
    const mean =
      this.#pending.reduce((sum, level) => sum + level, 0) /
      this.#pending.length;
    this.#pending = [];
    return mean;
  }

  reset() {
    this.#floorDb = INITIAL_FLOOR_DB;
    this.#pending = [];
  }
}
