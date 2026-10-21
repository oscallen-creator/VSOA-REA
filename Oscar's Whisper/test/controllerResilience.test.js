import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { Source, Status } from "../src/main/dictation/controller.js";
import {
  NO_AUDIO_DISMISS_MS,
  DICTATION_DEBOUNCE_DELAY_MS as WINDOW,
  DICTATION_DURATION_TIMEOUT_MS as TIMEOUT,
  DICTATION_DURATION_WARNING_MS as WARNING,
} from "../src/main/constants.js";
import { PCM, deferred, flush, setup } from "./support/controllerHarness.js";

const BUSY = "busy:previous_transcript_processing";

describe("busy", () => {
  for (const [stage, hang, status] of [
    [
      "processing",
      (gate) => ({ process: () => gate.promise }),
      Status.Processing,
    ],
    ["stopping", (gate) => ({ stop: () => gate.promise }), Status.Stopping],
  ]) {
    test(`new presses are ignored with a busy notice while ${stage}`, async () => {
      const gate = deferred();
      const h = setup(hang(gate));
      h.controller.toggleHandsFree();
      await flush();
      h.time.advance(WINDOW);
      h.controller.toggleHandsFree(); // re_press -> stop
      await flush();
      assert.equal(h.controller.status, status);
      assert.equal(h.time.pendingTimers(), 0); // stopping already cancelled every timer

      h.controller.pushToTalkDown();
      h.controller.toggleHandsFree(Source.Bar);
      h.controller.pushToTalkUp(); // not an active session: silently ignored
      h.controller.dismiss("test");
      assert.deepEqual(h.notices, [BUSY, BUSY]);
      assert.deepEqual([h.calls.start, h.controller.status], [1, status]);

      gate.resolve();
      await flush();
      assert.equal(h.controller.status, Status.Idle);
      h.controller.pushToTalkDown();
      assert.equal(h.calls.start, 2);
    });
  }
});

describe("failures", () => {
  test("a rejecting process() reports an error and returns to idle", async () => {
    const h = setup({
      process: async () => {
        throw new Error("paste failed");
      },
    });
    await h.hold();
    h.controller.pushToTalkUp();
    await flush();
    assert.deepEqual(h.notices, ["error:paste failed"]);
    assert.deepEqual(
      [h.controller.status, h.controller.isLocked, h.time.pendingTimers()],
      [Status.Idle, false, 0],
    );
  });

  test("a rejecting recorder.stop() reports an error and never calls process", async () => {
    const h = setup({
      stop: async () => {
        throw new Error("device lost");
      },
    });
    await h.hold();
    h.controller.pushToTalkUp();
    await flush();
    assert.deepEqual(h.notices, ["error:device lost"]);
    assert.deepEqual([h.processed, h.controller.status], [[], Status.Idle]);
  });

  test("a start() that finishes after stop() does not report listening", async () => {
    const gate = deferred();
    const h = setup({ start: () => gate.promise });
    h.controller.toggleHandsFree();
    h.time.advance(WINDOW);
    h.controller.toggleHandsFree();
    await flush();
    gate.resolve();
    await flush();
    assert.deepEqual(h.statuses(), [
      Status.Initializing,
      Status.Stopping,
      Status.Processing,
      Status.Idle,
    ]);
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "re_press" }]);
  });

  test("a start() failure while stop() awaits the recorder discards the recording", async () => {
    const startGate = deferred();
    const stopGate = deferred();
    const h = setup({
      start: () => startGate.promise,
      stop: () => stopGate.promise,
    });
    h.controller.toggleHandsFree();
    h.time.advance(WINDOW);
    h.controller.toggleHandsFree(); // stop while the recorder is still starting
    startGate.reject(new Error("mic denied"));
    await flush();
    stopGate.resolve();
    await flush();
    assert.deepEqual(h.notices, ["error:mic denied"]);
    assert.deepEqual([h.processed, h.controller.status], [[], Status.Idle]);
  });
});

describe("no-audio dismissal", () => {
  test("dismisses a dictation that has received no audio after the no-audio delay", async () => {
    const h = setup({ receivedAudio: () => false });
    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(NO_AUDIO_DISMISS_MS - 1);
    assert.equal(h.controller.status, Status.Listening);
    h.time.advance(1);
    assert.deepEqual(h.notices, ["dismissed:no_audio"]);
    assert.deepEqual(
      [h.controller.status, h.calls.cancel, h.processed],
      [Status.Idle, 1, []],
    );
  });

  test("keeps listening when audio arrived or the recorder cannot report it", async () => {
    for (const receivedAudio of [() => true, undefined]) {
      const h = setup({ receivedAudio });
      h.controller.toggleHandsFree();
      await flush();
      h.time.advance(2 * NO_AUDIO_DISMISS_MS);
      assert.deepEqual(
        [h.controller.status, h.notices],
        [Status.Listening, []],
      );
    }
  });
});

describe("duration limit", () => {
  test("warns at 19 minutes, then stops with duration_limit at 20 minutes", async () => {
    const h = setup();
    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(WARNING - 1);
    assert.deepEqual(h.notices, []);
    h.time.advance(1);
    assert.deepEqual(h.notices, ["warning:one_minute_left"]);
    assert.equal(h.controller.status, Status.Listening);
    h.time.advance(TIMEOUT - WARNING);
    await flush();
    assert.deepEqual(h.processed, [{ pcm: PCM, reason: "duration_limit" }]);
    assert.equal(h.controller.status, Status.Idle);
  });

  test("stopping and dismissing each cancel every pending timer", async () => {
    const h = setup();
    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(WINDOW);
    h.controller.toggleHandsFree(); // re_press -> stop
    await flush();
    assert.deepEqual([h.processed.length, h.time.pendingTimers()], [1, 0]);

    h.controller.toggleHandsFree();
    await flush();
    h.time.advance(WINDOW - 1);
    h.controller.toggleHandsFree(); // double_press -> dismiss
    await flush();
    assert.equal(h.time.pendingTimers(), 0);
    h.time.advance(TIMEOUT);
    assert.deepEqual(h.notices, ["dismissed:double_press"]);
  });

  test("a finished dictation's limit timers never fire into the next one", async () => {
    const h = setup();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(10 * 60_000);
    h.controller.pushToTalkUp();
    await flush();
    h.controller.pushToTalkDown();
    await flush();
    h.time.advance(10 * 60_000); // 20 minutes after the first start, 10 after the second
    assert.deepEqual([h.notices, h.controller.status], [[], Status.Listening]);
    h.time.advance(9 * 60_000);
    assert.deepEqual(h.notices, ["warning:one_minute_left"]);
  });
});
