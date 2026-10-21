#!/usr/bin/env node
// Command line for the background remover: the app's engine, input rules,
// output naming and error handling, driven by flags. Images are processed one
// at a time because the model already uses every core.

import { realpathSync } from "node:fs";
import { access, readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { defaultModelDir } from "./engine/modelStore.js";
import { MODELS } from "./engine/models.js";
import { OptionError, parseOptions } from "./engine/options.js";
import { classifyError } from "./main/engineErrors.js";
import { collectInputs, describeRejections } from "./main/inputs.js";
import { resultPath } from "./main/outputPath.js";
import { writeNewFile } from "./main/writeNew.js";

const EXIT = Object.freeze({ ok: 0, failed: 1, usage: 2 });
const DEFAULT_OUTPUT_DIR = "removed-bg";
// The same quality names the app offers.
const MODEL_ALIASES = Object.freeze({
  best: "isnet-general-use",
  fast: "u2netp",
});
const COUNT_KEY = { done: "done", skipped: "skipped", error: "failed" };

const FLAGS = {
  output: { type: "string", short: "o" },
  format: { type: "string" },
  size: { type: "string" },
  "bg-color": { type: "string" },
  "bg-image": { type: "string" },
  crop: { type: "boolean" },
  "crop-margin": { type: "string" },
  scale: { type: "string" },
  position: { type: "string" },
  roi: { type: "string" },
  channels: { type: "string" },
  type: { type: "string" },
  shadow: { type: "string" },
  "shadow-opacity": { type: "string" },
  model: { type: "string" },
  "models-dir": { type: "string" },
  quiet: { type: "boolean", short: "q" },
  json: { type: "boolean" },
  help: { type: "boolean", short: "h" },
  version: { type: "boolean", short: "v" },
};

// Flags that are passed to the engine as-is under its remove.bg-style key, so
// the engine's own parser stays the only place option values are interpreted.
const ENGINE_KEYS = {
  format: "format",
  size: "size",
  "bg-color": "bg_color",
  crop: "crop",
  "crop-margin": "crop_margin",
  scale: "scale",
  position: "position",
  roi: "roi",
  channels: "channels",
  type: "type",
  shadow: "shadow_type",
  "shadow-opacity": "shadow_opacity",
};

const HELP = `Usage: oscars-remove-bg [options] <file-or-folder>...

Removes image backgrounds locally. Folders are searched recursively and
names starting with "." are skipped. Results are never overwritten.

Output
  -o, --output <dir>         Folder for results (default: ./${DEFAULT_OUTPUT_DIR})
      --format <f>           png (default), jpg, webp, psd, zip or auto
      --size <s>             auto, preview or full
      --channels <c>         rgba (default) or alpha (matte only)

Background
      --bg-color <c>         Hex (#RGB, #RRGGBB, #RRGGBBAA) or a color name
      --bg-image <file>      Image to place behind the subject

Framing
      --crop                 Crop to the subject
      --crop-margin <v>      Margin around the crop, e.g. "10px" or "5% 2%"
      --scale <v>            original, or 10% to 100%
      --position <v>         original, center, or "x% y%"
      --roi "x1 y1 x2 y2"    Region to search for the subject
      --type <t>             auto, person or product

Shadow
      --shadow <t>           none, auto, car, 3D or drop
      --shadow-opacity <n>   0 to 100, or auto

Engine
      --model <m>            best (default), fast or one of:
                             ${Object.keys(MODELS).join(", ")}
      --models-dir <dir>     Where models are stored (downloaded on first use)

Reporting
  -q, --quiet                Only errors
      --json                 One JSON object per image, then a summary
  -h, --help                 Show this help
  -v, --version              Show the version

Exit status: 0 all done or skipped, 1 an image failed or the run stopped,
2 usage error.`;

class UsageError extends Error {}

const isUsageProblem = (error) =>
  error instanceof UsageError || error instanceof OptionError;

// parseArgs reports bad flags with ERR_PARSE_ARGS_* TypeErrors.
const parseCli = (argv) => {
  try {
    return parseArgs({
      args: argv,
      options: FLAGS,
      allowPositionals: true,
      strict: true,
    });
  } catch (error) {
    if (String(error?.code).startsWith("ERR_PARSE_ARGS_")) {
      throw new UsageError(error.message);
    }
    throw error;
  }
};

const readVersion = async () => {
  const file = new URL("../package.json", import.meta.url);
  return JSON.parse(await readFile(file, "utf8")).version;
};

const resolveModelId = (name = "best") => {
  const id = Object.hasOwn(MODEL_ALIASES, name) ? MODEL_ALIASES[name] : name;
  if (!Object.hasOwn(MODELS, id)) {
    const known = [...Object.keys(MODEL_ALIASES), ...Object.keys(MODELS)];
    throw new UsageError(
      `Unknown model ${JSON.stringify(name)}. Choose one of: ${known.join(", ")}`,
    );
  }
  return id;
};

const readBgImage = async (file, cwd) => {
  try {
    return await readFile(path.resolve(cwd, file));
  } catch (error) {
    throw new UsageError(`Cannot read --bg-image ${file}: ${error.message}`);
  }
};

const engineOptions = async (values, cwd) => {
  const options = { format: "png" };
  for (const [flag, key] of Object.entries(ENGINE_KEYS)) {
    if (values[flag] !== undefined) options[key] = values[flag];
  }
  if (values["bg-image"] !== undefined) {
    // Read once; every image reuses the same bytes.
    options.bg_image = await readBgImage(values["bg-image"], cwd);
  }
  return options;
};

// Validates everything before the model is touched, so a typo fails fast.
const prepare = async (values, { cwd, env }) => {
  const options = await engineOptions(values, cwd);
  return {
    options,
    parsed: parseOptions(options),
    modelId: resolveModelId(values.model),
    modelDir: path.resolve(
      cwd,
      values["models-dir"] ?? defaultModelDir({ env }),
    ),
    outputDir: path.resolve(cwd, values.output ?? DEFAULT_OUTPUT_DIR),
  };
};

// The extension is known before processing unless the engine decides: "auto"
// picks per image, and a matte is always its own format.
const plannedFormat = ({ format, channels }) =>
  format === "auto" || channels === "alpha" ? null : format;

const exists = async (file) => {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
};

/** Never throws: every failure becomes an outcome with a classified message. */
const processEntry = async (entry, { remover, options, parsed, outputDir }) => {
  const started = performance.now();
  const finish = (fields) => ({
    ...fields,
    ms: Math.round(performance.now() - started),
  });
  let output = null;
  try {
    const planned = plannedFormat(parsed);
    if (planned) {
      output = resultPath(outputDir, entry.relativePath, planned);
      if (await exists(output)) return finish({ status: "skipped", output });
    }
    const result = await remover.removeBackground(entry.sourcePath, options);
    output = resultPath(outputDir, entry.relativePath, result.format);
    const written = await writeNewFile(output, result.buffer);
    return finish({
      status: written ? "done" : "skipped",
      output,
      width: result.width,
      height: result.height,
      format: result.format,
    });
  } catch (error) {
    const { message, fatal } = classifyError(error);
    return finish({ status: "error", output, error: message, fatal });
  }
};

const megabytes = (bytes) => Math.round(bytes / 1e6);

// One line per 10%, even though the store reports every whole percent.
const downloadProgress = (modelId, print) => {
  let lastStep = 0;
  return ({ received, total }) => {
    const percent = Math.floor((received * 100) / total);
    const step = percent - (percent % 10);
    if (step <= lastStep) return;
    lastStep = step;
    print(
      `Downloading model ${modelId}: ${step}% (${megabytes(received)} of ${megabytes(total)} MB)`,
    );
  };
};

const jsonLine = (entry, outcome) => ({
  input: entry.sourcePath,
  output: outcome.output ?? null,
  status: outcome.status,
  width: outcome.width ?? null,
  height: outcome.height ?? null,
  format: outcome.format ?? null,
  ms: outcome.ms,
  error: outcome.error ?? null,
});

const describeOutcome = (entry, outcome) => {
  if (outcome.status === "skipped")
    return `skipped (exists): ${outcome.output}`;
  const { width, height, ms } = outcome;
  return `done ${entry.relativePath} -> ${outcome.output} (${width}x${height}, ${ms} ms)`;
};

// Results and the summary go to stdout; errors and progress to stderr, so
// piping stdout stays clean. --json moves every per-image line to stdout.
const createReporter = ({ say, warn, json, quiet }) => ({
  progress: (line) => {
    if (!json && !quiet) warn(line);
  },
  file(entry, outcome) {
    if (json) return say(JSON.stringify(jsonLine(entry, outcome)));
    if (outcome.status === "error") {
      return warn(`error ${entry.relativePath}: ${outcome.error}`);
    }
    if (!quiet) say(describeOutcome(entry, outcome));
  },
  summary(counts, ms) {
    if (json) return say(JSON.stringify({ summary: { ...counts, ms } }));
    if (counts.notProcessed > 0) {
      warn(`Stopped: ${counts.notProcessed} remaining image(s) not processed.`);
    }
    if (quiet) return;
    const seconds = (ms / 1000).toFixed(1);
    say(
      `${counts.done} done, ${counts.skipped} skipped, ${counts.failed} failed in ${seconds} s`,
    );
  },
});

const processAll = async (entries, context, reporter) => {
  const started = performance.now();
  const counts = { done: 0, skipped: 0, failed: 0 };
  let attempted = 0;
  for (const entry of entries) {
    attempted += 1;
    const outcome = await processEntry(entry, context);
    counts[COUNT_KEY[outcome.status]] += 1;
    reporter.file(entry, outcome);
    // Retrying the rest would only repeat the same failure.
    if (outcome.fatal) break;
  }
  reporter.summary(
    {
      ...counts,
      notProcessed: entries.length - attempted,
      rejected: context.rejected,
    },
    Math.round(performance.now() - started),
  );
  return counts.failed > 0 ? EXIT.failed : EXIT.ok;
};

const isInside = (directory, file) => file.startsWith(directory + path.sep);

// The default output folder often sits inside the folder being processed;
// without this a second run would treat its own results as inputs.
const withoutOwnOutput = (accepted, outputDir, warn) => {
  const kept = accepted.filter(
    ({ sourcePath }) => !isInside(outputDir, sourcePath),
  );
  const ignored = accepted.length - kept.length;
  if (ignored > 0)
    warn(`Ignoring ${ignored} file(s) inside the output folder.`);
  return kept;
};

// Loaded on demand: sharp and the ONNX runtime take a while to start, which
// --help and usage errors should not wait for.
const loadRemover = async (config) => {
  const { createRemover } = await import("./engine/removeBackground.js");
  return createRemover(config);
};

// Nothing useful can be done if releasing the model fails at exit.
const release = async (remover) => {
  try {
    await remover.dispose?.();
  } catch {
    // Ignored on purpose.
  }
};

const run = async (argv, io) => {
  const { values, positionals } = parseCli(argv);
  if (values.help || values.version) {
    io.say(values.help ? HELP : await readVersion());
    return EXIT.ok;
  }
  if (positionals.length === 0) {
    throw new UsageError("No input files or folders given.");
  }

  const setup = await prepare(values, io);
  const found = await collectInputs(
    positionals.map((input) => path.resolve(io.cwd, input)),
  );
  const note = describeRejections(found.accepted.length, found.rejected);
  if (note) io.warn(note);
  const entries = withoutOwnOutput(found.accepted, setup.outputDir, io.warn);
  if (entries.length === 0) throw new UsageError("No images to process.");

  const reporter = createReporter({
    ...io,
    json: values.json,
    quiet: values.quiet,
  });
  const remover = await io.createRemoverFn({
    modelId: setup.modelId,
    modelDir: setup.modelDir,
    onModelProgress: downloadProgress(setup.modelId, reporter.progress),
  });
  try {
    return await processAll(
      entries,
      { ...setup, remover, rejected: found.rejected.length },
      reporter,
    );
  } finally {
    await release(remover);
  }
};

/**
 * @param {string[]} argv arguments after the script name
 * @returns {Promise<number>} the exit code
 */
export const main = async (
  argv,
  {
    stdout = process.stdout,
    stderr = process.stderr,
    cwd = process.cwd(),
    createRemoverFn = loadRemover,
    env = process.env,
  } = {},
) => {
  const io = {
    cwd,
    env,
    createRemoverFn,
    say: (line) => stdout.write(`${line}\n`),
    warn: (line) => stderr.write(`${line}\n`),
  };
  try {
    return await run(argv, io);
  } catch (error) {
    io.warn(`error: ${error?.message ?? error}`);
    if (!isUsageProblem(error)) return EXIT.failed;
    io.warn("Run with --help for usage.");
    return EXIT.usage;
  }
};

// The real path of argv[1] also matches when started through a symlink such
// as an npm bin link.
const isEntryPoint = () => {
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
};

const flush = (stream) => new Promise((resolve) => stream.write("", resolve));

if (isEntryPoint()) {
  const code = await main(process.argv.slice(2));
  await Promise.all([flush(process.stdout), flush(process.stderr)]);
  process.exit(code);
}
