// Models are not committed to git. They are downloaded on first use from a
// pinned URL and trusted only once their SHA-256 matches the descriptor, so a
// half-written or tampered file never reaches the inference engine.

import { createHash, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  mkdir,
  open,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const APP_DIR = "Oscar's Remove BG";
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]*$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const SIDECAR_SUFFIX = ".verified";

/** In-flight preparations keyed by final path; see ensureModel(). */
const inFlight = new Map();

export class ModelDownloadError extends Error {
  /** @param code "http_status" | "size_mismatch" | "hash_mismatch" | "aborted" | "network" */
  constructor(code, message, { modelId, url, cause } = {}) {
    super(message, { cause });
    this.name = "ModelDownloadError";
    this.code = code;
    this.modelId = modelId;
    this.url = url;
  }
}

const failure = (model, code, message, cause) =>
  new ModelDownloadError(code, message, {
    modelId: model.id,
    url: model.url,
    cause,
  });

const cancelled = (model, cause) =>
  failure(
    model,
    "aborted",
    `Cancelled while preparing model ${model.id}`,
    cause,
  );

// A fetch or body-read error is either the caller's cancellation or a network
// problem; only the signal can tell them apart. The message carries the error
// and its cause (e.g. "fetch failed (ECONNREFUSED)") but never a response body.
const interrupted = (model, signal, error) => {
  if (signal?.aborted) return cancelled(model, error);
  const cause = error?.cause;
  const detail = cause
    ? `${error.message} (${cause.code ?? cause.message})`
    : (error?.message ?? String(error));
  return failure(
    model,
    "network",
    `Download of ${model.id} failed: ${detail}`,
    error,
  );
};

export const defaultModelDir = ({
  env = process.env,
  platform = process.platform,
  homedir = os.homedir(),
} = {}) => {
  if (env.OSCARS_REMOVE_BG_MODELS) return env.OSCARS_REMOVE_BG_MODELS;
  // Explicit win32/posix joins keep the result deterministic whatever the host.
  if (platform === "win32") {
    const base =
      env.LOCALAPPDATA || path.win32.join(homedir, "AppData", "Local");
    return path.win32.join(base, APP_DIR, "models");
  }
  if (platform === "darwin") {
    return path.posix.join(
      homedir,
      "Library",
      "Application Support",
      APP_DIR,
      "models",
    );
  }
  const cache = env.XDG_CACHE_HOME || path.posix.join(homedir, ".cache");
  return path.posix.join(cache, "oscars-remove-bg", "models");
};

export const modelPath = (model, dir) => {
  if (typeof model?.id !== "string" || !ID_PATTERN.test(model.id)) {
    throw new TypeError(`Invalid model id: ${JSON.stringify(model?.id)}`);
  }
  return path.join(dir, `${model.id}.onnx`);
};

const assertModel = (model) => {
  if (typeof model.url !== "string" || model.url === "") {
    throw new TypeError(`Model ${model.id} has no download url`);
  }
  if (!SHA256_PATTERN.test(model.sha256)) {
    throw new TypeError(`Model ${model.id} needs a lowercase hex sha256`);
  }
  if (!Number.isSafeInteger(model.bytes) || model.bytes <= 0) {
    throw new TypeError(`Model ${model.id} needs a positive byte size`);
  }
};

const statIfPresent = async (file) => {
  try {
    return await stat(file);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
};

const hashFile = async (model, file, signal) => {
  const hash = createHash("sha256");
  try {
    for await (const chunk of createReadStream(file, { signal })) {
      hash.update(chunk);
    }
  } catch (error) {
    throw signal?.aborted ? cancelled(model, error) : error;
  }
  return hash.digest("hex");
};

// The sidecar only saves re-hashing a large file on every launch, so any
// problem reading it just means "hash again".
const sidecarMatches = async (model, file, stats) => {
  try {
    const saved = JSON.parse(await readFile(file + SIDECAR_SUFFIX, "utf8"));
    return (
      saved?.sha256 === model.sha256 &&
      saved.bytes === stats.size &&
      saved.mtimeMs === stats.mtimeMs
    );
  } catch {
    return false;
  }
};

const writeSidecar = async (model, file, stats) => {
  const saved = {
    sha256: model.sha256,
    bytes: stats.size,
    mtimeMs: stats.mtimeMs,
  };
  try {
    await writeFile(file + SIDECAR_SUFFIX, JSON.stringify(saved));
  } catch {
    // The model is already verified; an unwritable cache hint must not fail it.
  }
};

// `stats` is taken before hashing so a write that races the hash leaves the
// sidecar stale (re-hashed next time) rather than vouching for unseen bytes.
const isVerified = async (model, file, stats, signal) => {
  if (await sidecarMatches(model, file, stats)) return true;
  if ((await hashFile(model, file, signal)) !== model.sha256) return false;
  await writeSidecar(model, file, stats);
  return true;
};

const openBody = async (model, fetch, signal) => {
  let response;
  try {
    response = await fetch(model.url, { redirect: "follow", signal });
  } catch (error) {
    throw interrupted(model, signal, error);
  }
  if (!response.ok) {
    // Drop the connection without reading the body, which is never reported.
    await response.body?.cancel().catch(() => {});
    throw failure(
      model,
      "http_status",
      `Download of ${model.id} failed with HTTP ${response.status}`,
    );
  }
  if (!response.body) {
    throw failure(
      model,
      "size_mismatch",
      `Download of ${model.id} returned no data (expected ${model.bytes} bytes)`,
    );
  }
  return response.body;
};

// FileHandle.write may write fewer bytes than asked.
const writeAll = async (handle, chunk) => {
  let offset = 0;
  while (offset < chunk.length) {
    const { bytesWritten } = await handle.write(
      chunk,
      offset,
      chunk.length - offset,
    );
    offset += bytesWritten;
  }
};

// Reports each time a whole percent is crossed; the last chunk crosses 100%.
const progressReporter = (total, onProgress) => {
  let lastPercent = 0;
  return (received) => {
    const percent = Math.floor((received * 100) / total);
    if (!onProgress || percent <= lastPercent) return;
    lastPercent = percent;
    try {
      onProgress({ received, total });
    } catch {
      // A faulty progress listener must not abort a large download.
    }
  };
};

// Writes the body to `partial` and returns its SHA-256. Stops as soon as more
// than model.bytes arrive, so a hostile or misconfigured server cannot make
// us buffer or write an unbounded stream.
const receive = async (model, body, partial, { signal, onProgress }) => {
  const hash = createHash("sha256");
  const report = progressReporter(model.bytes, onProgress);
  const reader = body.getReader();
  const read = async () => {
    if (signal?.aborted) throw cancelled(model, signal.reason);
    try {
      return await reader.read();
    } catch (error) {
      throw interrupted(model, signal, error);
    }
  };
  let handle;
  let received = 0;
  try {
    handle = await open(partial, "wx");
    for (let step = await read(); !step.done; step = await read()) {
      received += step.value.length;
      if (received > model.bytes) {
        throw failure(
          model,
          "size_mismatch",
          `Download of ${model.id} exceeded the expected ${model.bytes} bytes`,
        );
      }
      hash.update(step.value);
      await writeAll(handle, step.value);
      report(received);
    }
  } finally {
    // After a clean end this is a no-op; after an early exit it makes fetch
    // drop the connection instead of leaving the transfer running.
    await reader.cancel().catch(() => {});
    await handle?.close();
  }
  if (received !== model.bytes) {
    throw failure(
      model,
      "size_mismatch",
      `Download of ${model.id} ended after ${received} of ${model.bytes} bytes`,
    );
  }
  return hash.digest("hex");
};

const downloadModel = async (model, finalPath, options) => {
  await mkdir(path.dirname(finalPath), { recursive: true });
  const partial = `${finalPath}.partial-${randomBytes(8).toString("hex")}`;
  try {
    const body = await openBody(model, options.fetch, options.signal);
    const digest = await receive(model, body, partial, options);
    if (digest !== model.sha256) {
      throw failure(
        model,
        "hash_mismatch",
        `Download of ${model.id} failed verification: expected SHA-256 ${model.sha256}, got ${digest}`,
      );
    }
    // Rename keeps size and mtime, so these stats describe the final file.
    const stats = await stat(partial);
    await rename(partial, finalPath);
    await writeSidecar(model, finalPath, stats);
  } catch (error) {
    await rm(partial, { force: true }).catch(() => {});
    throw error;
  }
};

const prepareModel = async (model, finalPath, options) => {
  if (options.signal?.aborted) {
    throw cancelled(model, options.signal.reason);
  }
  const stats = await statIfPresent(finalPath);
  if (
    stats?.isFile() &&
    stats.size === model.bytes &&
    (await isVerified(model, finalPath, stats, options.signal))
  ) {
    return finalPath;
  }
  await downloadModel(model, finalPath, options);
  return finalPath;
};

/**
 * Resolves to the absolute path of a model file whose size and SHA-256 match
 * the descriptor, downloading it first if needed.
 *
 * Callers asking for the same final path while a preparation is running share
 * it, so the first caller's `signal` and `onProgress` govern the shared work:
 * a later caller's own signal does not cancel it and gets no progress events.
 */
export const ensureModel = async (
  model,
  {
    dir = defaultModelDir(),
    fetch = globalThis.fetch,
    signal,
    onProgress,
  } = {},
) => {
  const finalPath = path.resolve(modelPath(model, dir));
  assertModel(model);
  const running = inFlight.get(finalPath);
  if (running) return running;
  const task = prepareModel(model, finalPath, {
    fetch,
    signal,
    onProgress,
  }).finally(() => inFlight.delete(finalPath));
  inFlight.set(finalPath, task);
  return task;
};
