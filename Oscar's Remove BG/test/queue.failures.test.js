import { afterEach, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { AppStatus, SKIPPED_MESSAGE, createQueue } from "../src/main/queue.js";

const SRC = path.join(path.sep, "photos");
const BASE_SETTINGS = {
  outputPath: "",
  usePsd: false,
  shadow: "none",
  shadowOpacity: "none",
  bgMode: "transparent",
  bgColor: "#FFFFFF",
  size: "auto",
  quality: "best",
};
const NOT_WRITABLE =
  "Output folder is not writable. Please change output folder.";

let dir;
beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), "orbg-queue-"));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
};

const tick = () => new Promise((resolve) => setImmediate(resolve));

const waitFor = async (predicate, label) => {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() > deadline)
      throw new Error(`Timed out waiting for ${label}`);
    await tick();
  }
};

const entry = (relativePath) => ({
  sourcePath: path.join(SRC, ...relativePath.split("/")),
  relativePath,
});
const entries = (...names) => names.map(entry);

const fatal = (message = NOT_WRITABLE) =>
  Object.assign(new Error(message), { fatal: true });

/** Distinct consecutive values, to read a status history without repeats. */
const trail = (snapshots, pick) =>
  snapshots
    .map(pick)
    .filter((value, i, all) => i === 0 || value !== all[i - 1]);

/**
 * A queue wired to a fake engine. Without `runJob`, every job waits on a
 * deferred promise in `jobs` that the test settles by hand.
 */
const harness = ({ settings = {}, runJob, getSettings } = {}) => {
  const state = {
    settings: { ...BASE_SETTINGS, outputPath: dir, ...settings },
  };
  const calls = [];
  const jobs = [];
  const changes = [];
  const alerts = [];
  const engine =
    runJob ??
    ((job) => {
      const pending = deferred();
      jobs.push({ job, ...pending });
      return pending.promise;
    });
  const queue = createQueue({
    runJob: (job) => {
      calls.push(job);
      return engine(job);
    },
    getSettings: getSettings ?? (() => state.settings),
    onChange: (snapshot) => changes.push(snapshot),
    onAlert: (message) => alerts.push(message),
  });
  const statuses = () => queue.snapshot().rows.map((row) => row.status);
  const appStatus = () => queue.snapshot().status;
  const settle = () =>
    waitFor(
      () => ![AppStatus.Processing, AppStatus.Stopping].includes(appStatus()),
      "the run to settle",
    );
  const jobCount = (count) =>
    waitFor(() => jobs.length >= count, `job ${count} to start`);
  return {
    queue,
    state,
    calls,
    jobs,
    changes,
    alerts,
    statuses,
    appStatus,
    settle,
    jobCount,
  };
};

const done = { width: 640, height: 480 };

describe("queue existing outputs and failures", () => {
  test("an existing target is skipped without running the engine", async () => {
    await writeFile(path.join(dir, "a.png"), "old");
    const h = harness({ runJob: async () => done });
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.settle();
    const [skipped, next] = h.queue.snapshot().rows;
    assert.equal(skipped.status, "skipped");
    assert.equal(skipped.message, "Skipped: File already exists");
    assert.equal(SKIPPED_MESSAGE, "Skipped: File already exists");
    assert.deepEqual(skipped.output, {
      path: path.join(dir, "a.png"),
      format: "png",
    });
    assert.equal(next.status, "finished");
    assert.deepEqual(
      h.calls.map((job) => path.basename(job.sourcePath)),
      ["b.jpg"],
    );
    assert.equal(h.queue.snapshot().run.done, 2);
  });

  test("skipping honours subfolders and the chosen format", async () => {
    await mkdir(path.join(dir, "Trip"));
    await writeFile(path.join(dir, "Trip", "a.jpg"), "old");
    await writeFile(path.join(dir, "Trip", "b.png"), "other format");
    const h = harness({
      settings: { bgMode: "color" },
      runJob: async () => done,
    });
    h.queue.add(entries("Trip/a.png", "Trip/b.png"));
    h.queue.start();
    await h.settle();
    assert.deepEqual(h.statuses(), ["skipped", "finished"]);
    assert.equal(h.calls.length, 1);
  });

  test("a job that reports skipped:true becomes a skipped row", async () => {
    const h = harness({ runJob: async () => ({ skipped: true }) });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    const [row] = h.queue.snapshot().rows;
    assert.equal(row.status, "skipped");
    assert.equal(row.message, SKIPPED_MESSAGE);
    assert.equal(row.output.path, path.join(dir, "a.png"));
    assert.equal(h.queue.snapshot().run.done, 1);
    assert.equal(h.appStatus(), "finished");
  });
});

describe("queue job failures", () => {
  test("a non-fatal error marks only that row and the run continues", async () => {
    const h = harness({
      runJob: async (job) => {
        if (job.sourcePath.endsWith("b.jpg")) throw new Error("boom");
        return done;
      },
    });
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.settle();
    const rows = h.queue.snapshot().rows;
    assert.deepEqual(
      rows.map((r) => r.status),
      ["finished", "error", "finished"],
    );
    assert.equal(rows[1].message, "boom");
    assert.equal(rows[1].output, null);
    assert.equal(h.appStatus(), "finished");
    assert.equal(h.queue.snapshot().run.done, 3);
    assert.deepEqual(h.alerts, []);
  });

  test("rejections that are not Errors still mark the row", async () => {
    const h = harness({
      runJob: async () => {
        throw "plain failure";
      },
    });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    const [row] = h.queue.snapshot().rows;
    assert.equal(row.status, "error");
    assert.equal(row.message, "plain failure");
    assert.equal(h.appStatus(), "finished");
  });

  test("an unsafe relative path becomes an error row", async () => {
    const h = harness({ runJob: async () => done });
    h.queue.add([
      { sourcePath: path.join(SRC, "evil.jpg"), relativePath: "../evil.jpg" },
      entry("ok.jpg"),
    ]);
    h.queue.start();
    await h.settle();
    const rows = h.queue.snapshot().rows;
    assert.equal(rows[0].status, "error");
    assert.match(rows[0].message, /Unsafe relative path/);
    assert.equal(rows[1].status, "finished");
    assert.equal(h.calls.length, 1);
  });

  test("error rows are not retried by the next Start", async () => {
    const h = harness({
      runJob: async () => {
        throw new Error("bad image");
      },
    });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    assert.equal(h.queue.start(), false);
    assert.equal(h.calls.length, 1);
    assert.equal(h.statuses()[0], "error");
  });

  test("an unexpected failure outside a job resets to ready and alerts", async () => {
    const h = harness({
      getSettings: () => {
        throw new Error("settings unavailable");
      },
    });
    h.queue.add(entries("a.jpg"));
    assert.equal(h.queue.start(), true);
    await h.settle();
    assert.equal(h.appStatus(), "ready");
    assert.deepEqual(h.alerts, ["settings unavailable"]);
    assert.deepEqual(h.statuses(), ["ready"]);
    assert.equal(h.calls.length, 0);
  });
});

describe("queue fatal errors", () => {
  const withBrokenOutput = () => {
    const control = { broken: true };
    const h = harness({
      runJob: async (job) => {
        if (control.broken && job.sourcePath.endsWith("b.jpg")) throw fatal();
        return done;
      },
    });
    return { h, control };
  };

  test("stops the run, reverts the row, alerts once, leaves the rest", async () => {
    const { h } = withBrokenOutput();
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.settle();
    const rows = h.queue.snapshot().rows;
    assert.deepEqual(
      rows.map((r) => r.status),
      ["finished", "ready", "ready"],
    );
    assert.equal(rows[1].message, NOT_WRITABLE);
    assert.equal(rows[1].output, null);
    assert.equal(rows[2].message, "");
    assert.equal(h.appStatus(), "ready");
    assert.deepEqual(h.alerts, [NOT_WRITABLE]);
    assert.equal(h.calls.length, 2);
    assert.equal(h.queue.snapshot().run.done, 1);
    assert.deepEqual(
      trail(h.changes, (s) => s.status),
      ["ready", "processing", "ready"],
    );
  });

  test("a later Start retries the reverted and untouched rows", async () => {
    const { h, control } = withBrokenOutput();
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.settle();
    control.broken = false;
    assert.equal(h.queue.start(), true);
    await h.settle();
    assert.deepEqual(h.statuses(), ["finished", "finished", "finished"]);
    assert.equal(h.queue.snapshot().rows[1].message, "");
    assert.equal(h.queue.snapshot().run.total, 2);
    assert.deepEqual(
      h.calls.map((job) => path.basename(job.sourcePath)),
      ["a.jpg", "b.jpg", "b.jpg", "c.jpg"],
    );
    assert.equal(h.alerts.length, 1);
    assert.equal(h.appStatus(), "finished");
  });

  test("a fatal error on the only row leaves it ready", async () => {
    const h = harness({
      runJob: async () => {
        throw fatal("The image engine stopped unexpectedly (exit code 1).");
      },
    });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    assert.deepEqual(h.statuses(), ["ready"]);
    assert.equal(h.appStatus(), "ready");
    assert.equal(h.alerts.length, 1);
    assert.equal(h.queue.start(), true);
    await h.settle();
  });

  test("the list is editable again after a fatal stop", async () => {
    const { h } = withBrokenOutput();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.settle();
    assert.equal(h.queue.add(entries("c.jpg")).length, 1);
    h.queue.remove(1);
    assert.equal(h.queue.snapshot().rows.length, 2);
  });

  test("a fatal error while stopping ends in ready with one alert", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    h.jobs[0].reject(fatal());
    await h.settle();
    assert.equal(h.appStatus(), "ready");
    assert.deepEqual(h.statuses(), ["ready", "ready"]);
    assert.deepEqual(h.alerts, [NOT_WRITABLE]);
  });
});

describe("queue cancel", () => {
  test("lets the current job finish and leaves the rest ready", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    assert.equal(h.appStatus(), "stopping");
    assert.deepEqual(h.statuses(), ["processing", "ready", "ready"]);
    h.jobs[0].resolve(done);
    await h.settle();
    assert.equal(h.appStatus(), "finished");
    assert.deepEqual(h.statuses(), ["finished", "ready", "ready"]);
    assert.equal(h.calls.length, 1);
    assert.equal(h.queue.snapshot().run.done, 1);
    assert.deepEqual(h.alerts, []);
    assert.deepEqual(
      trail(h.changes, (s) => s.status),
      ["ready", "processing", "stopping", "finished"],
    );
  });

  test("blocks start and list edits until the run has stopped", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    assert.equal(h.queue.start(), false);
    assert.deepEqual(h.queue.add(entries("c.jpg")), []);
    h.queue.remove(2);
    h.queue.clear();
    assert.equal(h.queue.snapshot().rows.length, 2);
    h.jobs[0].resolve(done);
    await h.settle();
  });

  test("a stopped run can be started again for the remaining rows", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    h.jobs[0].resolve(done);
    await h.settle();
    assert.equal(h.queue.start(), true);
    await h.jobCount(2);
    h.jobs[1].resolve(done);
    await h.jobCount(3);
    h.jobs[2].resolve(done);
    await h.settle();
    assert.deepEqual(h.statuses(), ["finished", "finished", "finished"]);
    assert.equal(h.queue.snapshot().run.total, 2);
  });

  test("cancelling during the last job still ends finished", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    h.jobs[0].resolve(done);
    await h.settle();
    assert.equal(h.appStatus(), "finished");
    assert.deepEqual(h.statuses(), ["finished"]);
  });

  test("a job that fails non-fatally while stopping marks its row", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    h.jobs[0].reject(new Error("bad image"));
    await h.settle();
    assert.equal(h.appStatus(), "finished");
    assert.deepEqual(h.statuses(), ["error", "ready"]);
    assert.deepEqual(h.alerts, []);
  });
});

describe("queue cancel edge cases", () => {
  test("cancelling twice changes nothing the second time", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.queue.cancel();
    const published = h.changes.length;
    h.queue.cancel();
    assert.equal(h.changes.length, published);
    assert.equal(h.appStatus(), "stopping");
    h.jobs[0].resolve(done);
    await h.settle();
  });

  test("cancel is a no-op when idle", async () => {
    const h = harness({ runJob: async () => done });
    h.queue.add(entries("a.jpg"));
    const published = h.changes.length;
    h.queue.cancel();
    assert.equal(h.appStatus(), "ready");
    h.queue.start();
    await h.settle();
    const afterRun = h.changes.length;
    h.queue.cancel();
    assert.equal(h.appStatus(), "finished");
    assert.equal(h.changes.length, afterRun);
    assert.ok(afterRun > published);
    assert.equal(h.queue.start(), false);
  });
});
