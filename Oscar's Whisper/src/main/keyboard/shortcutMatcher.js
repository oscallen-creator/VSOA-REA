// Turns raw global key presses/releases into action down/up events.
// Mirrors Wispr's keyboard service: a map of held keys with timestamps, auto-repeat suppression,
// a periodic stale-key sweep, and exact matching of the held set against the bindings.

import { STALE_KEY_MS } from "../constants.js";
import { comboId, toLogicalKey } from "./keys.js";

export class ShortcutMatcher {
  #bindings;
  #onActionDown;
  #onActionUp;
  #now;
  #held = new Map();
  #active = null;

  constructor({ bindings, onActionDown, onActionUp, now = Date.now }) {
    this.#bindings = bindings;
    this.#onActionDown = onActionDown;
    this.#onActionUp = onActionUp;
    this.#now = now;
  }

  get heldKeys() {
    return [...this.#held.keys()].sort();
  }

  get activeAction() {
    return this.#active?.action ?? null;
  }

  press(keycode) {
    const key = toLogicalKey(keycode);
    const repeat = this.#held.has(key);
    this.#held.set(key, this.#now());
    if (repeat) return;
    const action = this.#bindings[comboId(this.#held.keys())];
    if (action && action !== this.#active?.action) {
      this.#active = { action, keys: new Set(this.#held.keys()) };
      this.#onActionDown(action);
    }
  }

  release(keycode) {
    const key = toLogicalKey(keycode);
    if (!this.#held.delete(key)) return;
    this.#releaseActiveIfBroken(key);
  }

  /** Drops keys whose key-up was never seen (e.g. lost while the screen was locked). */
  sweepStaleKeys() {
    const cutoff = this.#now() - STALE_KEY_MS;
    for (const [key, at] of this.#held) {
      if (at < cutoff && !this.#active?.keys.has(key)) {
        this.#held.delete(key);
      }
    }
  }

  reset() {
    this.#held.clear();
    this.#active = null;
  }

  #releaseActiveIfBroken(releasedKey) {
    if (!this.#active?.keys.has(releasedKey)) return;
    const { action } = this.#active;
    this.#active = null;
    this.#onActionUp(action);
  }
}
