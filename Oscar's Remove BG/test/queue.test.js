import { afterEach, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { AppStatus, RowStatus, createQueue } from "../src/main/queue.js";

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

describe("queue constants", () => {
  test("RowStatus and AppStatus name the documented states", () => {
    assert.deepEqual(
      { ...RowStatus },
      {
        Ready: "ready",
        Processing: "processing",
        Finished: "finished",
        Skipped: "skipped",
        Error: "error",
      },
    );
    assert.deepEqual(
      { ...AppStatus },
      {
        Ready: "ready",
        Processing: "processing",
        Stopping: "stopping",
        Finished: "finished",
      },
    );
    assert.ok(Object.isFrozen(RowStatus) && Object.isFrozen(AppStatus));
  });
});

describe("queue rows", () => {
  test("add() creates ready rows with ids, names and sources", () => {
    const { queue } = harness();
    const added = queue.add(entries("a.jpg", "Trip/sub/b.png"));
    assert.deepEqual(added, [
      {
        id: 1,
        sourcePath: path.join(SRC, "a.jpg"),
        relativePath: "a.jpg",
        name: "a.jpg",
        status: "ready",
        message: "",
        output: null,
      },
      {
        id: 2,
        sourcePath: path.join(SRC, "Trip", "sub", "b.png"),
        relativePath: "Trip/sub/b.png",
        name: "b.png",
        status: "ready",
        message: "",
        output: null,
      },
    ]);
    assert.deepEqual(queue.snapshot().rows, added);
    assert.equal(queue.snapshot().status, "ready");
    assert.equal(queue.snapshot().run, null);
  });

  test("ids keep increasing across adds and are never reused", () => {
    const { queue } = harness();
    queue.add(entries("a.jpg", "b.jpg"));
    queue.remove(2);
    const [row] = queue.add(entries("c.jpg"));
    assert.equal(row.id, 3);
    assert.deepEqual(
      queue.snapshot().rows.map((r) => r.id),
      [1, 3],
    );
  });

  test("add() publishes a snapshot with the new rows", () => {
    const { queue, changes } = harness();
    queue.add(entries("a.jpg"));
    assert.equal(changes.length, 1);
    assert.equal(changes[0].status, "ready");
    assert.deepEqual(
      changes[0].rows.map((r) => r.name),
      ["a.jpg"],
    );
  });

  test("add() with nothing still returns an empty list", () => {
    const { queue } = harness();
    assert.deepEqual(queue.add([]), []);
  });

  test("remove() drops only that row while idle", () => {
    const { queue } = harness();
    queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    queue.remove(2);
    assert.deepEqual(
      queue.snapshot().rows.map((r) => r.name),
      ["a.jpg", "c.jpg"],
    );
    queue.remove(99);
    assert.equal(queue.snapshot().rows.length, 2);
  });

  test("clear() empties the list, drops the run and returns to ready", async () => {
    const h = harness({ runJob: async () => done });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    assert.equal(h.appStatus(), "finished");
    h.queue.clear();
    assert.deepEqual(h.queue.snapshot(), {
      status: "ready",
      rows: [],
      run: null,
    });
  });
});

describe("queue sources", () => {
  test("knownSources() lists every row's source, whatever its status", async () => {
    const h = harness({
      runJob: async (job) => {
        if (job.sourcePath.endsWith("b.jpg")) throw new Error("bad");
        return done;
      },
    });
    h.queue.add(entries("a.jpg", "b.jpg", "Trip/c.jpg"));
    h.queue.start();
    await h.settle();
    const known = h.queue.knownSources();
    assert.ok(known instanceof Set);
    assert.deepEqual(
      [...known].sort(),
      entries("a.jpg", "b.jpg", "Trip/c.jpg")
        .map((e) => e.sourcePath)
        .sort(),
    );
    known.clear();
    assert.equal(h.queue.knownSources().size, 3);
    h.queue.remove(2);
    assert.equal(h.queue.knownSources().has(path.join(SRC, "b.jpg")), false);
  });

  test("findRow() returns the row with that id, or null", () => {
    const { queue } = harness();
    queue.add(entries("a.jpg", "b.jpg"));
    assert.equal(queue.findRow(2).name, "b.jpg");
    assert.equal(queue.findRow(3), null);
  });
});

describe("queue start", () => {
  test("returns false with no rows or no ready rows", async () => {
    const h = harness({ runJob: async () => done });
    assert.equal(h.queue.start(), false);
    assert.equal(h.appStatus(), "ready");
    h.queue.add(entries("a.jpg"));
    assert.equal(h.queue.start(), true);
    await h.settle();
    assert.equal(h.queue.start(), false);
    assert.equal(h.appStatus(), "finished");
    assert.equal(h.calls.length, 1);
  });

  test("enters processing synchronously and rejects a second start", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg"));
    assert.equal(h.queue.start(), true);
    assert.equal(h.appStatus(), "processing");
    assert.equal(h.queue.start(), false);
    await h.jobCount(1);
    assert.equal(h.jobs.length, 1);
    h.jobs[0].resolve(done);
    await h.settle();
  });

  test("processes rows in order, one at a time", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    h.queue.start();
    await h.jobCount(1);
    await tick();
    assert.equal(h.jobs.length, 1, "second job waits for the first");
    assert.deepEqual(h.statuses(), ["processing", "ready", "ready"]);
    h.jobs[0].resolve(done);
    await h.jobCount(2);
    assert.deepEqual(h.statuses(), ["finished", "processing", "ready"]);
    h.jobs[1].resolve(done);
    await h.jobCount(3);
    h.jobs[2].resolve(done);
    await h.settle();
    assert.deepEqual(
      h.calls.map((job) => path.basename(job.sourcePath)),
      ["a.jpg", "b.jpg", "c.jpg"],
    );
  });

  test("a row goes ready, processing, finished and the app follows", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.jobCount(1);
    h.jobs[0].resolve(done);
    await h.settle();
    assert.deepEqual(
      trail(h.changes, (s) => s.rows[0].status),
      ["ready", "processing", "finished"],
    );
    assert.deepEqual(
      trail(h.changes, (s) => s.status),
      ["ready", "processing", "finished"],
    );
  });

  test("a finished row carries the output and the engine's job payload", async () => {
    const h = harness();
    h.queue.add(entries("Trip/a.jpeg"));
    h.queue.start();
    await h.jobCount(1);
    assert.deepEqual(h.jobs[0].job, {
      sourcePath: path.join(SRC, "Trip", "a.jpeg"),
      resultPath: path.join(dir, "Trip", "a.png"),
      options: { size: "auto", format: "png", shadow_type: "none" },
      quality: "best",
    });
    h.jobs[0].resolve(done);
    await h.settle();
    const [row] = h.queue.snapshot().rows;
    assert.equal(row.status, "finished");
    assert.equal(row.message, "");
    assert.deepEqual(row.output, {
      path: path.join(dir, "Trip", "a.png"),
      format: "png",
      width: 640,
      height: 480,
      bgMode: "transparent",
    });
  });
});

describe("queue run settings", () => {
  test("settings choose the result format and extension", async () => {
    for (const [settings, ext, bgMode] of [
      [{ bgMode: "color" }, "jpg", "color"],
      [{ usePsd: true }, "psd", "transparent"],
      [{ bgMode: "color", usePsd: true }, "jpg", "color"],
    ]) {
      const h = harness({ settings, runJob: async () => done });
      h.queue.add(entries("a.webp"));
      h.queue.start();
      await h.settle();
      const [row] = h.queue.snapshot().rows;
      assert.equal(row.output.path, path.join(dir, `a.${ext}`));
      assert.equal(row.output.format, ext);
      assert.equal(row.output.bgMode, bgMode);
    }
  });

  test("uses the settings from the moment Start was pressed", async () => {
    const other = path.join(dir, "elsewhere");
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.jobCount(1);
    Object.assign(h.state.settings, {
      outputPath: other,
      bgMode: "color",
      usePsd: true,
      quality: "fast",
      size: "full",
    });
    h.jobs[0].resolve(done);
    await h.jobCount(2);
    h.state.settings = {
      ...h.state.settings,
      shadow: "car",
      shadowOpacity: 90,
    };
    h.jobs[1].resolve(done);
    await h.settle();
    for (const [index, name] of ["a", "b"].entries()) {
      const { job } = h.jobs[index];
      assert.equal(job.resultPath, path.join(dir, `${name}.png`));
      assert.deepEqual(job.options, {
        size: "auto",
        format: "png",
        shadow_type: "none",
      });
      assert.equal(job.quality, "best");
    }
    const run = h.queue.snapshot().run;
    assert.deepEqual([run.bgMode, run.format], ["transparent", "png"]);
    for (const row of h.queue.snapshot().rows) {
      assert.equal(row.output.bgMode, "transparent");
    }
  });
});

describe("queue run progress", () => {
  test("run progress counts total and done", async () => {
    const h = harness();
    const progress = () => {
      const { total, done: finished } = h.queue.snapshot().run;
      return { total, done: finished };
    };
    h.queue.add(entries("a.jpg", "b.jpg", "c.jpg"));
    assert.equal(h.queue.snapshot().run, null);
    h.queue.start();
    assert.deepEqual(progress(), { total: 3, done: 0 });
    for (let index = 0; index < 3; index += 1) {
      await h.jobCount(index + 1);
      assert.deepEqual(progress(), { total: 3, done: index });
      h.jobs[index].resolve(done);
      await waitFor(() => progress().done === index + 1, "progress");
    }
    await h.settle();
    assert.deepEqual(progress(), { total: 3, done: 3 });
  });

  test("a later run only covers rows that are ready", async () => {
    const h = harness({ runJob: async () => done });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    const [added] = h.queue.add(entries("b.jpg"));
    assert.equal(h.appStatus(), "finished");
    assert.equal(added.id, 2);
    assert.equal(h.queue.start(), true);
    await h.settle();
    assert.equal(h.queue.snapshot().run.total, 1);
    assert.deepEqual(
      h.calls.map((job) => path.basename(job.sourcePath)),
      ["a.jpg", "b.jpg"],
    );
    assert.deepEqual(h.statuses(), ["finished", "finished"]);
  });

  test("add, remove and clear are ignored while a run is active", async () => {
    const h = harness();
    h.queue.add(entries("a.jpg", "b.jpg"));
    h.queue.start();
    await h.jobCount(1);
    assert.deepEqual(h.queue.add(entries("c.jpg")), []);
    h.queue.remove(2);
    h.queue.clear();
    const snapshot = h.queue.snapshot();
    assert.deepEqual(
      snapshot.rows.map((r) => r.name),
      ["a.jpg", "b.jpg"],
    );
    assert.equal(snapshot.status, "processing");
    assert.notEqual(snapshot.run, null);
    h.jobs[0].resolve(done);
    await h.jobCount(2);
    h.jobs[1].resolve(done);
    await h.settle();
  });
});
