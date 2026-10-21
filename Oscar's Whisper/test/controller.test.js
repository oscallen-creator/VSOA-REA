import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { Source, Status } from "../src/main/dictation/controller.js";
import { DICTATION_DEBOUNCE_DELAY_MS as WINDOW } from "../src/main/constants.js";
import { PCM, deferred, flush, setup } from "./support/controllerHarness.js";

describe("push to talk", () => {
  test("pressing from idle starts unlocked: initializing, then listening", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    assert.deepEqual(h.changes, [
      { status: Status.Initializing, isLocked: false },
    ]);
    await flush();
    assert.deepEqual(h.changes.at(-1), {
      status: Status.Listening,
      isLocked: false,
    });
    assert.equal(h.calls.start, 1);
  });

  test("holding for the full window then releasing stops and processes with key_release", async () => {
    const h = setup();
    await h.hold();
    h.controller.pushToTalkUp();
    await flush();
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "key_release" }]);
    assert.deepEqual(h.statuses(), [
      Status.Initializing,
      Status.Listening,
      Status.Stopping,
      Status.Processing,
      Status.Idle,
    ]);
    assert.deepEqual([h.calls.stop, h.calls.cancel, h.notices], [1, 0, []]);
  });

  test("releasing inside the window processes nothing yet", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(WINDOW - 1);
    h.controller.pushToTalkUp();
    await flush();
    assert.equal(h.controller.status, Status.Listening);
    assert.deepEqual([h.processed, h.calls.stop, h.calls.cancel], [[], 0, 0]);
  });

  test("an early release with no second press dismisses as an accidental tap", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(200);
    h.controller.pushToTalkUp();
    h.time.advance(WINDOW - 1);
    assert.equal(h.controller.status, Status.Listening);
    h.time.advance(1);
    await flush();
    assert.equal(h.controller.status, Status.Idle);
    assert.deepEqual(h.notices, ["dismissed:accidental_tap"]);
    assert.deepEqual(
      [h.calls.cancel, h.calls.stop, h.processed, h.time.pendingTimers()],
      [1, 0, [], 0],
    );
  });

  test("a second press inside the window locks, and a later release does nothing", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    const limitTimers = h.time.pendingTimers();
    h.time.advance(100);
    h.controller.pushToTalkUp();
    assert.equal(h.time.pendingTimers(), limitTimers + 1); // plus the accidental-tap timer
    h.time.advance(100);
    h.controller.pushToTalkDown();
    assert.equal(h.time.pendingTimers(), limitTimers); // locking cancelled the tap timer
    assert.equal(h.controller.isLocked, true);
    assert.deepEqual(h.changes.at(-1), {
      status: Status.Listening,
      isLocked: true,
    });
    h.time.advance(10 * WINDOW);
    h.controller.pushToTalkUp();
    await flush();
    assert.equal(h.controller.status, Status.Listening);
    assert.deepEqual([h.notices, h.calls.cancel, h.calls.stop], [[], 0, 0]);
  });

  test("a third quick press while locked dismisses as triple_press", async () => {
    const h = setup();
    await h.lock();
    h.controller.pushToTalkUp();
    h.time.advance(50);
    h.controller.pushToTalkDown();
    await flush();
    assert.deepEqual(h.notices, ["dismissed:triple_press"]);
    assert.deepEqual(
      [h.controller.status, h.controller.isLocked, h.calls.cancel],
      [Status.Idle, false, 1],
    );
  });

  test("while locked, a press at or after the window edge stops with re_press", async () => {
    for (const elapsed of [WINDOW, WINDOW + 200, 2 * WINDOW]) {
      const h = setup();
      await h.lock(); // locked 200 ms after the first press
      h.time.advance(elapsed - 200);
      h.controller.pushToTalkDown();
      await flush();
      assert.deepEqual(h.processed, [{ pcm: PCM, reason: "re_press" }]);
      assert.deepEqual(
        [h.notices, h.controller.status, h.controller.isLocked],
        [[], Status.Idle, false],
      );
    }
  });

  test("while locked, a press one millisecond inside the window still dismisses", async () => {
    const h = setup();
    await h.lock();
    h.time.advance(WINDOW - 1 - 200);
    h.controller.pushToTalkDown();
    await flush();
    assert.deepEqual(
      [h.notices, h.processed],
      [["dismissed:triple_press"], []],
    );
  });

  test("releasing past the window before the recorder is ready dismisses, and a late start is ignored", async () => {
    const gate = deferred();
    const h = setup({ start: () => gate.promise });
    h.controller.pushToTalkDown();
    h.time.advance(WINDOW);
    h.controller.pushToTalkUp();
    assert.deepEqual(h.notices, ["dismissed:released_before_ready"]);
    assert.deepEqual([h.controller.status, h.calls.cancel], [Status.Idle, 1]);
    const changeCount = h.changes.length;
    gate.resolve();
    await flush();
    assert.equal(h.controller.status, Status.Idle);
    assert.equal(h.changes.length, changeCount);
  });

  for (const settle of ["resolve", "reject"]) {
    test(`a superseded start() that ${settle}s late leaves the newer dictation untouched`, async () => {
      const gates = [deferred(), deferred()];
      let call = 0;
      const h = setup({ start: () => gates[call++].promise });
      h.controller.pushToTalkDown();
      h.time.advance(WINDOW);
      h.controller.pushToTalkUp(); // released_before_ready: dismissed
      h.controller.pushToTalkDown(); // a new dictation begins
      gates[0][settle](new Error("late"));
      await flush();
      assert.equal(h.controller.status, Status.Initializing); // neither ready nor ended by the old start
      assert.deepEqual(h.notices, ["dismissed:released_before_ready"]);
      gates[1].resolve();
      await flush();
      assert.equal(h.controller.status, Status.Listening);
    });
  }

  test("a recorder start() rejection reports an error and ends idle", async () => {
    const h = setup({
      start: async () => {
        throw new Error("mic denied");
      },
    });
    h.controller.pushToTalkDown();
    await flush();
    assert.deepEqual(h.notices, ["error:mic denied"]);
    assert.deepEqual(h.statuses(), [Status.Initializing, Status.Idle]);
    assert.deepEqual([h.processed, h.time.pendingTimers()], [[], 0]);
  });

  test("a non-Error start() rejection is reported as its string form", async () => {
    const h = setup({ start: () => Promise.reject("denied") });
    h.controller.pushToTalkDown();
    await flush();
    assert.deepEqual(h.notices, ["error:denied"]);
  });
});

describe("hands-free toggle", () => {
  test("toggling from idle starts locked", async () => {
    const h = setup();
    h.controller.toggleHandsFree();
    assert.deepEqual(h.changes[0], {
      status: Status.Initializing,
      isLocked: true,
    });
    await flush();
    assert.deepEqual(h.changes.at(-1), {
      status: Status.Listening,
      isLocked: true,
    });
  });

  test("toggling again after the window stops with re_press", async () => {
    const h = setup();
    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(WINDOW);
    h.controller.toggleHandsFree();
    await flush();
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "re_press" }]);
    assert.equal(h.controller.status, Status.Idle);
  });

  test("toggling again inside the window dismisses as double_press", async () => {
    const h = setup();
    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(WINDOW - 1);
    h.controller.toggleHandsFree();
    await flush();
    assert.deepEqual(h.notices, ["dismissed:double_press"]);
    assert.deepEqual(
      [h.controller.status, h.calls.cancel, h.processed],
      [Status.Idle, 1, []],
    );
  });

  test("a bar click while listening unlocked stops with stop_button", async () => {
    const h = setup();
    await h.hold();
    h.controller.toggleHandsFree(Source.Bar);
    await flush();
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "stop_button" }]);
    assert.equal(h.controller.status, Status.Idle);
  });

  test("a bar click starts locked from idle and stops with stop_button after the window", async () => {
    const h = setup();
    h.controller.toggleHandsFree(Source.Bar);
    await flush();
    assert.equal(h.controller.isLocked, true);
    h.time.advance(WINDOW);
    h.controller.toggleHandsFree(Source.Bar);
    await flush();
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "stop_button" }]);
  });

  test("the keyboard toggle while holding push-to-talk locks instead of stopping", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(100);
    h.controller.toggleHandsFree(Source.Keyboard);
    assert.equal(h.controller.isLocked, true);
    h.time.advance(WINDOW);
    h.controller.pushToTalkUp();
    await flush();
    assert.deepEqual(
      [h.controller.status, h.calls.start, h.calls.stop, h.processed],
      [Status.Listening, 1, 0, []],
    );
  });

  test("a keyboard toggle during the accidental-tap wait keeps the locked session alive", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(200);
    h.controller.pushToTalkUp(); // starts the accidental-tap wait
    h.time.advance(100);
    h.controller.toggleHandsFree(Source.Keyboard);
    h.time.advance(WINDOW);
    assert.deepEqual(
      [h.controller.status, h.controller.isLocked, h.notices],
      [Status.Listening, true, []],
    );
  });
});
