// Shared harness for the DictationController tests: a fake clock/timers pair, a fake recorder
// and spies for `process`, `onChange` and `onNotice`. It defines no tests of its own.
import { DictationController } from "../../src/main/dictation/controller.js";
import { DICTATION_DEBOUNCE_DELAY_MS } from "../../src/main/constants.js";

export const PCM = Buffer.from([1, 2]);

/** Lets pending promise callbacks run without waiting on any timer. */
export const flush = () => new Promise((resolve) => setImmediate(resolve));

export const deferred = () => {
  const gate = {};
  gate.promise = new Promise((resolve, reject) =>
    Object.assign(gate, { resolve, reject }),
  );
  return gate;
};

/** Manually advanced clock plus fake setTimeout/clearTimeout; due timers fire in time order. */
export const createFakeTime = () => {
  let current = 1_000;
  let nextId = 1;
  const pending = new Map();
  return {
    now: () => current,
    timers: {
      setTimeout: (fn, ms) => (
        pending.set(nextId, { at: current + ms, fn }),
        nextId++
      ),
      clearTimeout: (id) => void pending.delete(id),
    },
    pendingTimers: () => pending.size,
    advance(ms) {
      const target = current + ms;
      for (;;) {
        const due = [...pending]
          .filter(([, t]) => t.at <= target)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        pending.delete(due[0]);
        current = due[1].at;
        due[1].fn();
      }
      current = target;
    },
  };
};

/**
 * `start`, `stop` and `process` optionally override the fake recorder/process behaviour
 * (return or throw to simulate gates and failures); the recorder resolves with PCM otherwise.
 * `receivedAudio` adds the optional recorder probe used by the no-audio dismissal.
 */
export const setup = ({
  start,
  stop,
  process: processImpl,
  receivedAudio,
} = {}) => {
  const time = createFakeTime();
  const calls = { start: 0, stop: 0, cancel: 0 };
  const changes = [];
  const notices = [];
  const processed = [];
  const recorder = {
    start: async () => (calls.start++, start?.()),
    stop: async () => (calls.stop++, await stop?.(), PCM),
    cancel: async () => void calls.cancel++,
    ...(receivedAudio && { receivedAudio }),
  };
  const controller = new DictationController({
    recorder,
    process: async (pcm, { reason }) => (
      processed.push({ pcm, reason }),
      processImpl?.()
    ),
    onChange: (state) => changes.push(state),
    onNotice: (notice) => notices.push(notice),
    now: time.now,
    timers: time.timers,
  });
  return {
    controller,
    time,
    calls,
    changes,
    notices,
    processed,
    statuses: () => changes.map((change) => change.status),
    /** Press and wait until the debounce window has fully elapsed. */
    async hold() {
      controller.pushToTalkDown();
      await flush();
      time.advance(DICTATION_DEBOUNCE_DELAY_MS);
    },
    /** Press, release quickly, press again: enters locked hands-free. */
    async lock() {
      controller.pushToTalkDown();
      await flush();
      time.advance(100);
      controller.pushToTalkUp();
      time.advance(100);
      controller.pushToTalkDown();
    },
  };
};
