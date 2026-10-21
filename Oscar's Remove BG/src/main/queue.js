// The image list and its run, following remove.bg desktop's states:
// rows are ready → processing → finished / error (plus "skipped" when the
// output already exists); the app is ready → processing → (stopping) →
// finished. Cancel stops starting new images and lets the current one finish.
// A fatal problem (output folder not writable, model unavailable) stops the
// run and is reported once, without the stalled queue remove.bg could leave.

import { access } from "node:fs/promises";
import path from "node:path";
import { outputFormat, resultPath } from "./outputPath.js";

export const RowStatus = Object.freeze({
  Ready: "ready",
  Processing: "processing",
  Finished: "finished",
  Skipped: "skipped",
  Error: "error",
});

export const AppStatus = Object.freeze({
  Ready: "ready",
  Processing: "processing",
  Stopping: "stopping",
  Finished: "finished",
});

export const SKIPPED_MESSAGE = "Skipped: File already exists";

const exists = async (file) => {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
};

/** Settings → remove.bg-style engine options. */
export const engineOptions = (settings) => {
  const options = {
    size: settings.size,
    format: outputFormat(settings),
    shadow_type: settings.shadow,
  };
  if (settings.shadow !== "none" && settings.shadowOpacity !== "none") {
    options.shadow_opacity = settings.shadowOpacity;
  }
  if (settings.bgMode === "color") options.bg_color = settings.bgColor;
  return options;
};

const newRow = (id, { sourcePath, relativePath }) => ({
  id,
  sourcePath,
  relativePath,
  name: path.basename(sourcePath),
  status: RowStatus.Ready,
  message: "",
  output: null,
});

/** Runs one row; `update` applies a patch to it and publishes the change. */
const processRow = async ({ row, settings, runJob, update }) => {
  const format = outputFormat(settings);
  const target = resultPath(settings.outputPath, row.relativePath, format);
  update({ status: RowStatus.Processing, message: "" });
  if (await exists(target)) {
    update({
      status: RowStatus.Skipped,
      message: SKIPPED_MESSAGE,
      output: { path: target, format },
    });
    return;
  }
  const result = await runJob({
    sourcePath: row.sourcePath,
    resultPath: target,
    options: engineOptions(settings),
    quality: settings.quality,
  });
  const skipped = result.skipped === true;
  update({
    status: skipped ? RowStatus.Skipped : RowStatus.Finished,
    message: skipped ? SKIPPED_MESSAGE : "",
    output: { ...result, path: target, format, bgMode: settings.bgMode },
  });
};

// A fatal row goes back to ready so Start retries it once the cause is fixed.
const failurePatchFor = (error) => ({
  status: error?.fatal ? RowStatus.Ready : RowStatus.Error,
  message: error?.message ?? String(error),
});

/**
 * @param {object} deps
 * @param {(job) => Promise<object>} deps.runJob runs one job; rejects with
 *   an error carrying `code` and optionally `fatal: true`
 * @param {() => object} deps.getSettings current settings
 * @param {(snapshot) => void} deps.onChange
 * @param {(message: string) => void} deps.onAlert
 */
export const createQueue = ({ runJob, getSettings, onChange, onAlert }) => {
  let rows = [];
  let status = AppStatus.Ready;
  let nextId = 1;
  let run = null;

  const copyRow = (row) => ({
    ...row,
    output: row.output && { ...row.output },
  });
  const snapshot = () => ({
    status,
    rows: rows.map(copyRow),
    run: run && { ...run },
  });
  const changed = () => onChange(snapshot());
  const idle = () =>
    status === AppStatus.Ready || status === AppStatus.Finished;

  const add = (entries) => {
    if (!idle()) return [];
    const added = entries.map((entry) => newRow(nextId++, entry));
    rows.push(...added);
    changed();
    return added.map(copyRow);
  };

  const remove = (id) => {
    if (!idle()) return;
    rows = rows.filter((row) => row.id !== id);
    changed();
  };

  const clear = () => {
    if (!idle()) return;
    rows = [];
    run = null;
    status = AppStatus.Ready;
    changed();
  };

  const knownSources = () => new Set(rows.map((row) => row.sourcePath));

  const updater = (row) => (patch) => {
    Object.assign(row, patch);
    changed();
  };

  const runAll = async () => {
    // One snapshot per run: changing settings mid-run cannot mix outputs.
    const settings = { ...getSettings() };
    const pending = rows.filter((row) => row.status === RowStatus.Ready);
    run = { total: pending.length, done: 0, bgMode: settings.bgMode };
    run.format = outputFormat(settings);
    for (const row of pending) {
      if (status === AppStatus.Stopping) break;
      if (!rows.includes(row)) continue;
      const update = updater(row);
      try {
        await processRow({ row, settings, runJob, update });
      } catch (error) {
        update(failurePatchFor(error));
        if (error?.fatal) {
          status = AppStatus.Ready;
          changed();
          onAlert(error.message);
          return;
        }
      }
      run.done += 1;
      changed();
    }
    status = AppStatus.Finished;
    changed();
  };

  const start = () => {
    if (!idle()) return false;
    if (!rows.some((row) => row.status === RowStatus.Ready)) return false;
    status = AppStatus.Processing;
    changed();
    runAll().catch((error) => {
      status = AppStatus.Ready;
      changed();
      onAlert(error.message);
    });
    return true;
  };

  const cancel = () => {
    if (status !== AppStatus.Processing) return;
    status = AppStatus.Stopping;
    changed();
  };

  const findRow = (id) => {
    const row = rows.find((candidate) => candidate.id === id);
    return row ? copyRow(row) : null;
  };

  return { add, remove, clear, start, cancel, snapshot, knownSources, findRow };
};
