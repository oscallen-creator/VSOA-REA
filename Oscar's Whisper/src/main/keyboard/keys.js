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

/** Right-hand modifiers also have names of their own, so one can be bound alone. */
const RIGHT_HAND = new Map([
  [0x0e1d, "rctrl"],
  [0x0e38, "ralt"],
  [0x0036, "rshift"],
  [0x0e5c, "rwin"],
]);
const RIGHT_HAND_NAMES = new Set(RIGHT_HAND.values());

export const toSidedKey = (keycode) =>
  RIGHT_HAND.get(keycode) ?? toLogicalKey(keycode);

/** Canonical binding id: logical keys sorted and joined, e.g. "ctrl+space+win". */
export const comboId = (keys) => [...new Set(keys)].sort().join("+");

export const MODIFIERS = new Set(["ctrl", "win", "alt", "shift"]);

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

/**
 * The defaults, minus every action the user's shortcuts rebind, plus those shortcuts. So
 * {"ctrl+shift": "ptt"} replaces the default push-to-talk keys instead of adding a second set.
 */
export const effectiveBindings = (shortcuts, platform = process.platform) => {
  const rebound = new Set(Object.values(shortcuts));
  const defaults = Object.entries(defaultBindings(platform)).filter(
    ([, action]) => !rebound.has(action),
  );
  return { ...Object.fromEntries(defaults), ...shortcuts };
};

const SINGLE_KEYS = new Set(["rctrl", "ralt", "rwin"]);
const unsided = (key) => (RIGHT_HAND_NAMES.has(key) ? key.slice(1) : key);

/**
 * Turns recorded keys (right-hand modifiers named apart) into push-to-talk keys, or null.
 * Allowed: one right-hand Control, Option or Command, which shortcuts rarely use, or two or
 * more modifiers on either side. Holding them never types a character, and ordinary typing
 * doesn't set them off.
 */
export const pushToTalkKeys = (recorded) => {
  if (recorded.length === 1 && SINGLE_KEYS.has(recorded[0])) return recorded;
  const keys = [...new Set(recorded.map(unsided))];
  return keys.length >= 2 && keys.every((key) => MODIFIERS.has(key))
    ? keys
    : null;
};

/** Moves push-to-talk to new keys; hands-free follows as the same keys plus Space. */
export const withPushToTalk = (shortcuts, keys) => ({
  ...Object.fromEntries(
    Object.entries(shortcuts).filter(
      ([, action]) => action !== Action.PushToTalk && action !== Action.HandsFree,
    ),
  ),
  [comboId(keys)]: Action.PushToTalk,
  [comboId([...keys, "space"])]: Action.HandsFree,
});
