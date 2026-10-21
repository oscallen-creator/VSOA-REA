// Logical key names and default bindings. Left/right modifier variants collapse to one name,
// so a binding such as "ctrl+win" matches either physical Ctrl or Windows key.

/** libuiohook virtual key codes (the same codes uiohook-napi reports). */
const KEYCODE_TO_LOGICAL = new Map([
  [0x001d, "ctrl"],
  [0x0e1d, "ctrl"],
  [0x0038, "alt"],
  [0x0e38, "alt"],
  [0x002a, "shift"],
  [0x0036, "shift"],
  [0x0e5b, "win"],
  [0x0e5c, "win"],
  [0x0039, "space"],
  [0x0001, "esc"],
]);

export const toLogicalKey = (keycode) =>
  KEYCODE_TO_LOGICAL.get(keycode) ?? `key${keycode}`;

/** Canonical binding id: logical keys sorted and joined, e.g. "ctrl+space+win". */
export const comboId = (keys) => [...new Set(keys)].sort().join("+");

export const Action = Object.freeze({
  PushToTalk: "ptt",
  HandsFree: "popo",
  Dismiss: "dismiss",
});

/**
 * Wispr's Windows defaults: hold Ctrl+Win to talk, Ctrl+Win+Space toggles hands-free.
 * On macOS, Wispr's Fn defaults need its native helper; its alternate Ctrl+Option set is used instead
 * ("win" is the Command key there and "alt" is Option).
 */
export const defaultBindings = (platform = process.platform) =>
  platform === "darwin"
    ? {
        [comboId(["ctrl", "alt"])]: Action.PushToTalk,
        [comboId(["ctrl", "alt", "space"])]: Action.HandsFree,
        esc: Action.Dismiss,
      }
    : {
        [comboId(["ctrl", "win"])]: Action.PushToTalk,
        [comboId(["ctrl", "win", "space"])]: Action.HandsFree,
        esc: Action.Dismiss,
      };
