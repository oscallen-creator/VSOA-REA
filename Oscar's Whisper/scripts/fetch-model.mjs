// Downloads the bundled speech-to-text model into models/<id>/ (git-ignored), checks the
// archive's SHA-256, and unpacks only the files the app needs. It does nothing when the model
// is already in place, so `npm start` and `npm run dist*` can always run it first.
// Behind an HTTP proxy, set HTTPS_PROXY and NODE_USE_ENV_PROXY=1.

import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import * as tar from "tar";
import unbzip2 from "unbzip2-stream";
import { SPEECH_MODEL } from "../src/main/transcription/speechModel.js";

const appRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const modelsDir = path.join(appRoot, "models");
const modelDir = path.join(modelsDir, SPEECH_MODEL.id);
const downloadDir = path.join(modelsDir, ".download");
const archive = path.join(downloadDir, `${SPEECH_MODEL.id}.tar.bz2`);
/** Written last; holds the archive hash the files came from. */
const marker = path.join(modelDir, ".complete");
const wanted = new Set([
  ...Object.values(SPEECH_MODEL.files),
  SPEECH_MODEL.sampleWav,
]);

const log = (message) => console.log(`[fetch-model] ${message}`);

const exists = (file) =>
  stat(file).then(
    () => true,
    () => false,
  );

const isInstalled = async () => {
  const recorded = await readFile(marker, "utf8").catch(() => "");
  if (recorded.trim() !== SPEECH_MODEL.archiveSha256) return false;
  const present = await Promise.all(
    [...wanted].map((file) => exists(path.join(modelDir, file))),
  );
  return present.every(Boolean);
};

const sha256File = async (file) => {
  const hash = createHash("sha256");
  await pipeline(createReadStream(file), hash);
  return hash.digest("hex");
};

const download = async () => {
  if (
    (await exists(archive)) &&
    (await sha256File(archive)) === SPEECH_MODEL.archiveSha256
  ) {
    log("using the archive downloaded earlier");
    return;
  }
  await mkdir(downloadDir, { recursive: true });
  const partial = `${archive}.part`;
  log(
    `downloading ${(SPEECH_MODEL.archiveBytes / 1e6).toFixed(0)} MB from ${SPEECH_MODEL.archiveUrl}`,
  );
  const response = await fetch(SPEECH_MODEL.archiveUrl);
  if (!response.ok || !response.body) {
    throw new Error(`Download failed: HTTP ${response.status}`);
  }
  const hash = createHash("sha256");
  let received = 0;
  let reported = 0;
  const meter = new Transform({
    transform(chunk, _encoding, done) {
      hash.update(chunk);
      received += chunk.length;
      const percent = Math.floor((received / SPEECH_MODEL.archiveBytes) * 100);
      if (percent >= reported + 10) {
        reported = percent - (percent % 10);
        log(`${reported}%`);
      }
      done(null, chunk);
    },
  });
  await pipeline(
    Readable.fromWeb(response.body),
    meter,
    createWriteStream(partial),
  );
  const digest = hash.digest("hex");
  if (digest !== SPEECH_MODEL.archiveSha256) {
    await rm(partial, { force: true });
    throw new Error(
      `Downloaded archive has SHA-256 ${digest}, expected ${SPEECH_MODEL.archiveSha256}`,
    );
  }
  await rename(partial, archive);
};

/** The archive holds one top-level folder; keep only the wanted files below it. */
const extract = async () => {
  const staging = `${modelDir}.partial`;
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  log("unpacking");
  await pipeline(
    createReadStream(archive),
    unbzip2(),
    tar.x({
      cwd: staging,
      strip: 1,
      preserveOwner: false,
      filter: (entryPath) =>
        wanted.has(entryPath.split("/").slice(1).join("/")),
    }),
  );
  for (const file of wanted) {
    if (!(await exists(path.join(staging, file)))) {
      throw new Error(`The model archive has no ${file}`);
    }
  }
  await writeFile(path.join(staging, ".complete"), SPEECH_MODEL.archiveSha256);
  await rm(modelDir, { recursive: true, force: true });
  await rename(staging, modelDir);
};

const main = async () => {
  if (await isInstalled()) {
    log(`${SPEECH_MODEL.id} is ready`);
    return;
  }
  await download();
  await extract();
  await rm(downloadDir, { recursive: true, force: true });
  log(`${SPEECH_MODEL.id} is ready in ${path.relative(appRoot, modelDir)}`);
};

main().catch((error) => {
  console.error(`[fetch-model] ${error.message}`);
  process.exitCode = 1;
});
