import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { ShortcutMatcher } from "../src/main/keyboard/shortcutMatcher.js";
import {
  Action,
  comboId,
  defaultBindings,
  effectiveBindings,
  pushToTalkKeys,
  toLogicalKey,
  withPushToTalk,
} from "../src/main/keyboard/keys.js";
import { STALE_KEY_MS } from "../src/main/constants.js";

// libuiohook key codes
const Ctrl = 0x001d,
  CtrlRight = 0x0e1d,
  Alt = 0x0038,
  AltRight = 0x0e38;
const Shift = 0x002a,
  ShiftRight = 0x0036,
  Win = 0x0e5b,
  WinRight = 0x0e5c;
const Space = 0x0039,
  Esc = 0x0001,
  KeyA = 0x001e;

const setup = (bindings = defaultBindings("win32")) => {
  let t = 1_000;
  const events = [];
  const matcher = new ShortcutMatcher({
    bindings,
    onActionDown: (action) => events.push(`down:${action}`),
    onActionUp: (action) => events.push(`up:${action}`),
    now: () => t,
  });
  const press = (...codes) => codes.forEach((code) => matcher.press(code));
  const release = (...codes) => codes.forEach((code) => matcher.release(code));
  return { matcher, events, press, release, advance: (ms) => (t += ms) };
};

describe("keys", () => {
  test("left and right modifiers collapse to one logical key", () => {
    const expected = {
      ctrl: [Ctrl, CtrlRight],
      alt: [Alt, AltRight],
      shift: [Shift, ShiftRight],
      win: [Win, WinRight],
      space: [Space],
      esc: [Esc],
    };
    for (const [name, codes] of Object.entries(expected)) {
      for (const code of codes) assert.equal(toLogicalKey(code), name);
    }
  });

  test("unknown key codes get a distinct fallback name", () => {
    assert.equal(toLogicalKey(KeyA), `key${KeyA}`);
    assert.notEqual(toLogicalKey(0x0030), toLogicalKey(0x0031));
  });

  test("comboId is order-independent and ignores duplicates", () => {
    assert.equal(comboId(["win", "ctrl"]), "ctrl+win");
    assert.equal(comboId(["ctrl", "win", "ctrl"]), "ctrl+win");
    assert.equal(comboId(["win", "space", "ctrl"]), "ctrl+space+win");
  });

  test("defaults: ctrl+win / ctrl+win+space on windows and linux, ctrl+alt / ctrl+alt+space on darwin", () => {
    const standard = {
      "ctrl+win": "ptt",
      "ctrl+space+win": "popo",
      esc: "dismiss",
    };
    assert.deepEqual(
      { ...Action },
      { PushToTalk: "ptt", HandsFree: "popo", Dismiss: "dismiss" },
    );
    assert.deepEqual(defaultBindings("win32"), standard);
    assert.deepEqual(defaultBindings("linux"), standard);
    assert.deepEqual(defaultBindings("darwin"), {
      [comboId(["ctrl", "alt"])]: "ptt",
      [comboId(["ctrl", "alt", "space"])]: "popo",
      esc: "dismiss",
    });
  });
});

describe("push to talk", () => {
  test("Ctrl and Win fire ptt down once, in either order and with either hand", () => {
    const orders = [
      [Ctrl, Win],
      [Win, Ctrl],
      [CtrlRight, WinRight],
      [Ctrl, WinRight],
      [WinRight, CtrlRight],
    ];
    for (const order of orders) {
      const { events, press } = setup();
      press(order[0]);
      assert.deepEqual(events, []); // one modifier alone is not a binding
      press(order[1]);
      assert.deepEqual(events, ["down:ptt"]);
    }
  });

  test("auto-repeat key-downs do not refire", () => {
    const { events, press } = setup();
    press(Ctrl, Win, Win, Win, Ctrl, Win);
    assert.deepEqual(events, ["down:ptt"]);
  });

  test("exposes the held keys (sorted) and the active action", () => {
    const { matcher, press, release } = setup();
    press(Win);
    assert.equal(matcher.activeAction, null);
    press(Ctrl);
    assert.deepEqual(matcher.heldKeys, ["ctrl", "win"]);
    assert.equal(matcher.activeAction, Action.PushToTalk);
    release(Ctrl, Win);
    assert.deepEqual(matcher.heldKeys, []);
    assert.equal(matcher.activeAction, null);
  });

  for (const [name, first, second] of [
    ["Ctrl", Ctrl, Win],
    ["Win", Win, Ctrl],
  ]) {
    test(`releasing ${name} first fires ptt up exactly once`, () => {
      const { events, press, release } = setup();
      press(Ctrl, Win);
      release(first);
      release(second);
      assert.deepEqual(events, ["down:ptt", "up:ptt"]);
    });
  }

  test("releasing a key that was never pressed is ignored", () => {
    const { events, release } = setup();
    release(Ctrl, KeyA);
    assert.deepEqual(events, []);
  });

  test("pressing the combo again after release fires ptt down again", () => {
    const { events, press, release } = setup();
    press(Ctrl, Win);
    release(Win);
    press(Win);
    assert.deepEqual(events, ["down:ptt", "up:ptt", "down:ptt"]);
  });
});

describe("hands-free", () => {
  test("adding Space while Ctrl+Win is held fires popo down", () => {
    const { matcher, events, press } = setup();
    press(Ctrl, Win);
    press(Space);
    assert.deepEqual(events, ["down:ptt", "down:popo"]);
    assert.equal(matcher.activeAction, Action.HandsFree);
  });

  test("releasing Space ends popo with a single popo up", () => {
    const { events, press, release } = setup();
    press(Ctrl, Win, Space);
    release(Space);
    release(Win, Ctrl);
    assert.deepEqual(
      events.filter((e) => e.endsWith(":popo")),
      ["down:popo", "up:popo"],
    );
  });

  test("auto-repeat of modifiers still held after Space is released does not fire ptt", () => {
    const { events, press, release } = setup();
    press(Ctrl, Win, Space);
    release(Space);
    press(Ctrl, Win); // OS key-repeat for the keys that are still down
    assert.deepEqual(events, ["down:ptt", "down:popo", "up:popo"]);
  });

  test("Ctrl+Space+Win in any press order is hands-free", () => {
    const { events, press } = setup();
    press(Ctrl, Space, Win);
    assert.deepEqual(events, ["down:popo"]);
  });
});

describe("matching", () => {
  test("an extra key held first (an unrelated key or Shift) prevents a match", () => {
    for (const extra of [KeyA, Shift]) {
      const { events, press } = setup();
      press(extra, Ctrl, Win);
      assert.deepEqual(events, []);
    }
  });

  test("an unrelated key added to the combo does not match or cancel it", () => {
    const { matcher, events, press, release } = setup();
    press(Ctrl, Win, KeyA);
    assert.deepEqual(events, ["down:ptt"]);
    release(KeyA);
    assert.equal(matcher.activeAction, Action.PushToTalk);
    assert.deepEqual(events, ["down:ptt"]);
  });

  test("Esc fires dismiss down and up", () => {
    const { events, press, release } = setup();
    press(Esc);
    release(Esc);
    assert.deepEqual(events, ["down:dismiss", "up:dismiss"]);
  });

  test("darwin bindings fire on Ctrl+Alt and Ctrl+Alt+Space, not Ctrl+Win", () => {
    const noMatch = setup(defaultBindings("darwin"));
    noMatch.press(Ctrl, Win);
    assert.deepEqual(noMatch.events, []);
    const mac = setup(defaultBindings("darwin"));
    mac.press(AltRight, CtrlRight, Space);
    assert.deepEqual(mac.events, ["down:ptt", "down:popo"]);
  });

  test("a second combo bound to the already-active action does not fire down again", () => {
    const { events, press } = setup({
      "ctrl+win": "ptt",
      "ctrl+shift+win": "ptt",
    });
    press(Ctrl, Win, Shift);
    assert.deepEqual(events, ["down:ptt"]);
  });

  test("custom bindings are honoured", () => {
    const { events, press } = setup({
      [comboId(["shift", "space"])]: "custom",
    });
    press(ShiftRight, Space);
    assert.deepEqual(events, ["down:custom"]);
  });
});

describe("stale key sweep and reset", () => {
  test("removes non-active keys older than the stale limit, keeps ones at or under it", () => {
    const { matcher, press, advance } = setup();
    press(KeyA);
    advance(STALE_KEY_MS); // exactly at the limit is not yet "older than" it
    matcher.sweepStaleKeys();
    assert.deepEqual(matcher.heldKeys, [`key${KeyA}`]);
    advance(1);
    matcher.sweepStaleKeys();
    assert.deepEqual(matcher.heldKeys, []);
  });

  test("keeps stale keys that belong to the active combo", () => {
    const { matcher, events, press, advance } = setup();
    press(Ctrl, Win, KeyA); // KeyA is held alongside, but is not part of the active combo
    advance(STALE_KEY_MS + 10_000);
    matcher.sweepStaleKeys();
    assert.deepEqual(matcher.heldKeys, ["ctrl", "win"]);
    assert.equal(matcher.activeAction, Action.PushToTalk);
    assert.deepEqual(events, ["down:ptt"]);
  });

  test("a repeated key-down refreshes the key's age", () => {
    const { matcher, press, advance } = setup();
    press(KeyA);
    advance(50_000);
    press(KeyA);
    advance(50_000);
    matcher.sweepStaleKeys();
    assert.deepEqual(matcher.heldKeys, [`key${KeyA}`]);
    advance(11_000);
    matcher.sweepStaleKeys();
    assert.deepEqual(matcher.heldKeys, []);
  });

  test("sweeping a stuck key lets the combo match again and emits no up event", () => {
    const { matcher, events, press, advance } = setup();
    press(KeyA); // its key-up was lost
    advance(STALE_KEY_MS + 1);
    matcher.sweepStaleKeys();
    assert.deepEqual(events, []);
    press(Ctrl, Win);
    assert.deepEqual(events, ["down:ptt"]);
  });

  test("reset releases the active action, clears held keys, and allows a new match", () => {
    const { matcher, events, press } = setup();
    press(Ctrl, Win);
    matcher.reset();
    assert.deepEqual(matcher.heldKeys, []);
    assert.equal(matcher.activeAction, null);
    press(Ctrl, Win);
    assert.deepEqual(events, ["down:ptt", "up:ptt", "down:ptt"]);
  });

  test("with both Ctrl keys down, releasing one does not release the combo", () => {
    const { matcher, events, press, release } = setup();
    press(Ctrl, CtrlRight, Win);
    release(Ctrl);
    assert.deepEqual(events, ["down:ptt"]);
    assert.deepEqual(matcher.heldKeys, ["ctrl", "win"]);
    release(CtrlRight);
    assert.deepEqual(events, ["down:ptt", "up:ptt"]);
  });
});

describe("changing push-to-talk", () => {
  test("a user binding replaces the default for its action instead of adding to it", () => {
    assert.deepEqual(effectiveBindings({ "ctrl+shift": "ptt" }, "darwin"), {
      "alt+ctrl+space": Action.HandsFree,
      esc: Action.Dismiss,
      "ctrl+shift": Action.PushToTalk,
    });
  });

  test("new push-to-talk keys move hands-free too and keep other shortcuts", () => {
    const old = { "alt+ctrl": "ptt", "alt+ctrl+space": "popo", esc: "dismiss" };
    assert.deepEqual(withPushToTalk(old, ["shift", "ctrl"]), {
      esc: Action.Dismiss,
      "ctrl+shift": Action.PushToTalk,
      "ctrl+shift+space": Action.HandsFree,
    });
  });

  test("push-to-talk is two or more modifiers, or one right-hand Control, Option or Command", () => {
    assert.deepEqual(pushToTalkKeys(["ctrl", "shift"]), ["ctrl", "shift"]);
    assert.deepEqual(pushToTalkKeys(["ctrl", "ralt"]), ["ctrl", "alt"]);
    assert.deepEqual(pushToTalkKeys(["ralt"]), ["ralt"]);
    assert.deepEqual(pushToTalkKeys(["rwin"]), ["rwin"]);
    assert.equal(pushToTalkKeys(["alt"]), null);
    assert.equal(pushToTalkKeys(["rshift"]), null);
    assert.equal(pushToTalkKeys(["ctrl", "rctrl"]), null);
    assert.equal(pushToTalkKeys(["ctrl", "space"]), null);
    assert.equal(pushToTalkKeys(["ctrl", toLogicalKey(KeyA)]), null);
  });

  test("Right Option alone can be bound, and Left Option then does nothing", () => {
    const h = setup(effectiveBindings(withPushToTalk({}, ["ralt"]), "darwin"));
    h.press(Alt);
    h.release(Alt);
    h.press(AltRight);
    h.press(Space);
    h.release(Space, AltRight);
    assert.deepEqual(h.events, ["down:ptt", "down:popo", "up:popo"]);
  });

  test("recording returns the most keys held at once, after all are released", async () => {
    const h = setup();
    const recorded = h.matcher.record();
    h.press(Ctrl, Shift);
    h.release(Shift);
    h.press(Alt);
    h.release(Ctrl, Alt);
    assert.deepEqual(await recorded, ["ctrl", "shift"]);
  });

  test("recording names right-hand modifiers apart", async () => {
    const h = setup();
    const recorded = h.matcher.record();
    h.press(AltRight);
    h.release(AltRight);
    assert.deepEqual(await recorded, ["ralt"]);
  });

  test("no action fires while recording, and bindings work again after setBindings", async () => {
    const h = setup();
    const recorded = h.matcher.record();
    h.press(Ctrl, Win);
    h.release(Ctrl, Win);
    assert.deepEqual(await recorded, ["ctrl", "win"]);
    assert.deepEqual(h.events, []);
    h.matcher.setBindings({ "ctrl+shift": Action.PushToTalk });
    h.press(Ctrl, Win);
    h.release(Ctrl, Win);
    h.press(Ctrl, Shift);
    h.release(Shift);
    assert.deepEqual(h.events, ["down:ptt", "up:ptt"]);
  });

  test("cancelling, or starting a second recording, resolves the first with no keys", async () => {
    const h = setup();
    const first = h.matcher.record();
    const second = h.matcher.record();
    assert.deepEqual(await first, []);
    h.press(Ctrl);
    h.matcher.cancelRecording();
    assert.deepEqual(await second, []);
  });

  test("starting a recording releases a held action", () => {
    const h = setup();
    h.press(Ctrl, Win);
    void h.matcher.record();
    assert.deepEqual(h.events, ["down:ptt", "up:ptt"]);
  });
});
