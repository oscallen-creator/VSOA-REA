import { afterEach, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { AppStatus, createQueue, engineOptions } from "../src/main/queue.js";

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

describe("queue snapshots", () => {
  const finishedQueue = async () => {
    const h = harness({ runJob: async () => done });
    h.queue.add(entries("a.jpg"));
    h.queue.start();
    await h.settle();
    return h;
  };

  test("snapshot() returns copies of status, rows and run", async () => {
    const h = await finishedQueue();
    const snapshot = h.queue.snapshot();
    snapshot.status = "ready";
    snapshot.rows[0].status = "error";
    snapshot.rows[0].name = "changed";
    snapshot.rows.push({ id: 99 });
    snapshot.run.done = 99;
    const fresh = h.queue.snapshot();
    assert.equal(fresh.status, "finished");
    assert.equal(fresh.rows.length, 1);
    assert.equal(fresh.rows[0].status, "finished");
    assert.equal(fresh.rows[0].name, "a.jpg");
    assert.equal(fresh.run.done, 1);
  });

  test("snapshots do not alias each other", async () => {
    const h = await finishedQueue();
    assert.notEqual(h.queue.snapshot(), h.queue.snapshot());
    assert.notEqual(h.queue.snapshot().rows[0], h.queue.snapshot().rows[0]);
    assert.notEqual(h.queue.snapshot().run, h.queue.snapshot().run);
  });

  test("onChange receives point-in-time snapshots", async () => {
    const h = await finishedQueue();
    const first = h.changes[0];
    assert.equal(first.status, "ready");
    assert.equal(first.rows[0].status, "ready");
    assert.equal(first.rows[0].output, null);
    assert.equal(first.run, null);
    const last = h.changes.at(-1);
    assert.equal(last.status, "finished");
    assert.equal(last.rows[0].status, "finished");
    assert.deepEqual(last, h.queue.snapshot());
    const processing = h.changes.find((s) => s.rows[0].status === "processing");
    assert.equal(processing.status, "processing");
    assert.equal(processing.run.done, 0);
    assert.equal(new Set(h.changes).size, h.changes.length);
  });

  test("mutating a published snapshot does not touch the queue", async () => {
    const h = await finishedQueue();
    h.changes.at(-1).rows[0].status = "error";
    assert.equal(h.statuses()[0], "finished");
  });

  test("a row's nested output object is copied too", async () => {
    const h = await finishedQueue();
    const snapshot = h.queue.snapshot();
    snapshot.rows[0].output.path = "/tampered.png";
    assert.equal(
      h.queue.snapshot().rows[0].output.path,
      path.join(dir, "a.png"),
    );
  });

  test("add() returns detached rows rather than the queue's own", () => {
    const { queue } = harness();
    const [added] = queue.add(entries("a.jpg"));
    added.status = "error";
    assert.equal(queue.snapshot().rows[0].status, "ready");
  });
});

describe("engineOptions", () => {
  const options = (overrides) =>
    engineOptions({ ...BASE_SETTINGS, ...overrides });

  test("defaults map to size, png format and no shadow", () => {
    assert.deepEqual(options({}), {
      size: "auto",
      format: "png",
      shadow_type: "none",
    });
  });

  test("passes the chosen size through", () => {
    for (const size of ["auto", "preview", "full"]) {
      assert.equal(options({ size }).size, size);
    }
  });

  test("format follows the background mode and the Photoshop option", () => {
    assert.equal(options({ usePsd: true }).format, "psd");
    assert.equal(options({ bgMode: "color" }).format, "jpg");
    assert.equal(options({ bgMode: "color", usePsd: true }).format, "jpg");
  });

  test("shadow type and opacity are passed when both are set", () => {
    assert.deepEqual(options({ shadow: "car", shadowOpacity: 90 }), {
      size: "auto",
      format: "png",
      shadow_type: "car",
      shadow_opacity: 90,
    });
    assert.equal(
      options({ shadow: "auto", shadowOpacity: "auto" }).shadow_opacity,
      "auto",
    );
    assert.equal(
      options({ shadow: "drop", shadowOpacity: 0 }).shadow_opacity,
      0,
    );
  });

  test("shadow_opacity is omitted for shadow none or opacity none", () => {
    assert.equal(
      Object.hasOwn(options({ shadow: "none" }), "shadow_opacity"),
      false,
    );
    assert.equal(
      Object.hasOwn(
        options({ shadow: "none", shadowOpacity: 50 }),
        "shadow_opacity",
      ),
      false,
    );
    const noOpacity = options({ shadow: "3D", shadowOpacity: "none" });
    assert.equal(Object.hasOwn(noOpacity, "shadow_opacity"), false);
    assert.equal(noOpacity.shadow_type, "3D");
  });

  test("bg_color is only sent for color mode", () => {
    const color = options({ bgMode: "color", bgColor: "#E10051" });
    assert.equal(color.bg_color, "#E10051");
    const transparent = options({ bgMode: "transparent", bgColor: "#E10051" });
    assert.equal(Object.hasOwn(transparent, "bg_color"), false);
  });

  test("does not include quality or the output path", () => {
    const keys = Object.keys(
      options({ bgMode: "color", shadow: "car", shadowOpacity: 90 }),
    );
    assert.deepEqual(keys.sort(), [
      "bg_color",
      "format",
      "shadow_opacity",
      "shadow_type",
      "size",
    ]);
  });
});
