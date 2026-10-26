// Turns raw global key presses/releases into action down/up events.
// Mirrors Wispr's keyboard service: a map of held keys with timestamps, auto-repeat suppression,
// a periodic stale-key sweep, and exact matching of the held set against the bindings.
// Physical keys are tracked separately, so holding both Ctrl keys and releasing one does not
// count as releasing "ctrl".

import { STALE_KEY_MS } from "../constants.js";
import { comboId, toLogicalKey, toSidedKey } from "./keys.js";

export class ShortcutMatcher {
  #bindings;
  #onActionDown;
  #onActionUp;
  #now;
  /** Physical keycode -> time of its last press or auto-repeat. */
  #held = new Map();
  #active = null;
  /** While recording a new shortcut: the most keys held at once, and who is waiting for them. */
  #recording = null;

  constructor({ bindings, onActionDown, onActionUp, now = Date.now }) {
    this.#bindings = bindings;
    this.#onActionDown = onActionDown;
    this.#onActionUp = onActionUp;
    this.#now = now;
  }

  setBindings(bindings) {
    this.reset();
    this.#bindings = bindings;
  }

  /**
   * Resolves with the most keys held at once (right-hand modifiers named apart, e.g. "ralt")
   * once they are all released. No action fires meanwhile. A second call, or
   * `cancelRecording()`, resolves the first with [].
   */
  record() {
    this.cancelRecording();
    this.reset();
    return new Promise((resolve) => {
      this.#recording = { peak: [], resolve };
    });
  }

  cancelRecording() {
    this.#finishRecording([]);
  }

  /** Logical names of the keys currently down, sorted and unique. */
  get heldKeys() {
    return [...this.#logicalHeld()].sort();
  }

  get activeAction() {
    return this.#active?.action ?? null;
  }

  press(keycode) {
    const repeat = this.#held.has(keycode);
    this.#held.set(keycode, this.#now());
    if (repeat) return;
    if (this.#recording) {
      const held = this.#sidedHeld();
      if (held.length > this.#recording.peak.length)
        this.#recording.peak = held;
      return;
    }
    const keys = this.#logicalHeld();
    // A binding such as "ralt" (Right Option alone) names one side of a modifier.
    const action =
      this.#bindings[comboId(keys)] ??
      this.#bindings[comboId(this.#sidedHeld())];
    if (action && action !== this.#active?.action) {
      this.#active = { action, keys };
      this.#onActionDown(action);
    }
  }

  release(keycode) {
    if (!this.#held.delete(keycode)) return;
    if (this.#recording) {
      if (this.#held.size === 0) this.#finishRecording(this.#recording.peak);
      return;
    }
    const key = toLogicalKey(keycode);
    if (this.#logicalHeld().has(key)) return;
    this.#releaseActiveIfBroken(key);
  }

  /** Drops keys whose key-up was never seen (e.g. lost while the screen was locked). */
  sweepStaleKeys() {
    const cutoff = this.#now() - STALE_KEY_MS;
    for (const [keycode, at] of this.#held) {
      if (at < cutoff && !this.#active?.keys.has(toLogicalKey(keycode))) {
        this.#held.delete(keycode);
      }
    }
  }

  /** Forgets all held keys; an action still held is released first. */
  reset() {
    this.#held.clear();
    const active = this.#active;
    this.#active = null;
    if (active) this.#onActionUp(active.action);
  }

  #finishRecording(keys) {
    const recording = this.#recording;
    this.#recording = null;
    recording?.resolve(keys);
  }

  #sidedHeld() {
    return [...this.#held.keys()].map(toSidedKey).sort();
  }

  #logicalHeld() {
    return new Set([...this.#held.keys()].map(toLogicalKey));
  }

  #releaseActiveIfBroken(releasedKey) {
    if (!this.#active?.keys.has(releasedKey)) return;
    const { action } = this.#active;
    this.#active = null;
    this.#onActionUp(action);
  }
}
