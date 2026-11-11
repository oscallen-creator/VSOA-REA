// Downloads the bundled speech-to-text model into models/<id>/ (git-ignored) from one pinned
// commit and checks every file's SHA-256, so every build gets exactly the same model. Files
// already in place with the right hash are kept, so `npm start` and `npm run dist*` can always
// run it first. Behind an HTTP proxy, set HTTPS_PROXY and NODE_USE_ENV_PROXY=1.

import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { SPEECH_MODEL } from "../src/main/transcription/speechModel.js";

const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const modelDir = path.join(appRoot, "models", SPEECH_MODEL.id);
/** Written last; holds the URL the files came from, so later runs skip hashing 661 MB. */
const marker = path.join(modelDir, ".complete");
const files = Object.entries(SPEECH_MODEL.sha256);

const log = (message) => console.log(`[fetch-model] ${message}`);

const exists = (file) =>
  stat(file).then(
    () => true,
    () => false,
  );

const isInstalled = async () => {
  const recorded = await readFile(marker, "utf8").catch(() => "");
  if (recorded.trim() !== SPEECH_MODEL.baseUrl) return false;
  const present = await Promise.all(
    files.map(([file]) => exists(path.join(modelDir, file))),
  );
  return present.every(Boolean);
};

/** The file's SHA-256, or null when it does not exist. */
const sha256File = async (file) => {
  const hash = createHash("sha256");
  return pipeline(createReadStream(file), hash).then(
    () => hash.digest("hex"),
    () => null,
  );
};

const download = async (file, expected) => {
  const target = path.join(modelDir, file);
  const partial = `${target}.part`;
  const response = await fetch(`${SPEECH_MODEL.baseUrl}/${file}`);
  if (!response.ok || !response.body) {
    throw new Error(`Download of ${file} failed: HTTP ${response.status}`);
  }
  const total = Number(response.headers.get("content-length")) || 0;
  log(`downloading ${file} (${(total / 1e6).toFixed(0)} MB)`);
  const hash = createHash("sha256");
  let received = 0;
  let reported = 0;
  const meter = new Transform({
    transform(chunk, _encoding, done) {
      hash.update(chunk);
      received += chunk.length;
      const percent = total > 100e6 ? Math.floor((received / total) * 100) : 0;
      if (percent >= reported + 10) {
        reported = percent - (percent % 10);
        log(`${reported}%`);
      }
      done(null, chunk);
    },
  });
  await mkdir(path.dirname(target), { recursive: true });
  await pipeline(
    Readable.fromWeb(response.body),
    meter,
    createWriteStream(partial),
  );
  const digest = hash.digest("hex");
  if (digest !== expected) {
    await rm(partial, { force: true });
    throw new Error(`${file} has SHA-256 ${digest}, expected ${expected}`);
  }
  await rename(partial, target);
};

const main = async () => {
  if (await isInstalled()) {
    log(`${SPEECH_MODEL.id} is ready`);
    return;
  }
  for (const [file, expected] of files) {
    if ((await sha256File(path.join(modelDir, file))) === expected) continue;
    await download(file, expected);
  }
  await writeFile(marker, SPEECH_MODEL.baseUrl);
  log(`${SPEECH_MODEL.id} is ready in ${path.relative(appRoot, modelDir)}`);
};

main().catch((error) => {
  console.error(`[fetch-model] ${error.message}`);
  process.exitCode = 1;
});
