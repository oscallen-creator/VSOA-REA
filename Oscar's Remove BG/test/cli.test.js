import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { main } from "../src/cli.js";

const execFileAsync = promisify(execFile);
const CLI = fileURLToPath(new URL("../src/cli.js", import.meta.url));
const PACKAGE = fileURLToPath(new URL("../package.json", import.meta.url));
const DOWNLOAD_BYTES = 178_648_008;

const unknownForeground = () =>
  Object.assign(new Error("Could not identify foreground in image."), {
    code: "unknown_foreground",
  });
const downloadFailed = () =>
  Object.assign(new Error("x"), { name: "ModelDownloadError" });
// Makes the fake fail on files with this name.
const failOn = (name, error) => (file) => {
  if (file.endsWith(name)) throw error();
};
const reportDownload = (file, options, config) => {
  for (let percent = 1; percent <= 100; percent += 1) {
    const received = (DOWNLOAD_BYTES * percent) / 100;
    config.onModelProgress({ received, total: DOWNLOAD_BYTES });
  }
};

let root;
let counter = 0;

before(async () => {
  root = await mkdtemp(path.join(tmpdir(), "oscars-cli-"));
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

const readVersion = async () =>
  JSON.parse(await readFile(PACKAGE, "utf8")).version;

const exists = (file) =>
  readFile(file).then(
    () => true,
    () => false,
  );

// A fresh directory with source files under "in" (contents are never decoded)
// and `existing` result files already in "out".
const workspace = async (names = [], existing = []) => {
  const dir = path.join(root, `case-${++counter}`);
  const input = path.join(dir, "in");
  const output = path.join(dir, "out");
  for (const [base, list] of [
    [input, names],
    [output, existing],
  ]) {
    for (const name of list) {
      await mkdir(path.dirname(path.join(base, name)), { recursive: true });
      await writeFile(path.join(base, name), `keep:${name}`);
    }
  }
  await mkdir(dir, { recursive: true });
  const files = names
    .filter((name) => name.endsWith(".png"))
    .map((name) => path.join(input, name));
  return { dir, input, output, files };
};

// Runs main() with a fake remover and collects everything it did.
const run = async (argv, { respond, cwd = root, env = {} } = {}) => {
  const out = [];
  const err = [];
  const seen = {
    calls: [],
    configs: [],
    inFlight: 0,
    maxInFlight: 0,
    disposed: 0,
  };
  const fake = (config) => ({
    removeBackground: async (file, options) => {
      seen.calls.push({ file, options });
      seen.inFlight += 1;
      seen.maxInFlight = Math.max(seen.maxInFlight, seen.inFlight);
      try {
        await new Promise((resolve) => setImmediate(resolve));
        const given = await respond?.(file, options, config);
        return {
          buffer: Buffer.from(`result:${path.basename(file)}`),
          format: options.format === "auto" ? "png" : options.format,
          width: 40,
          height: 30,
          ...given,
        };
      } finally {
        seen.inFlight -= 1;
      }
    },
    dispose: async () => {
      seen.disposed += 1;
    },
  });
  const code = await main(argv, {
    stdout: { write: (text) => out.push(text) },
    stderr: { write: (text) => err.push(text) },
    cwd,
    env,
    createRemoverFn: (config) => {
      seen.configs.push(config);
      return fake(config);
    },
  });
  return { ...seen, code, stdout: out.join(""), stderr: err.join("") };
};

// Processes the workspace's image files into its output folder.
const runSpace = (space, flags = [], options) =>
  run([...flags, "-o", space.output, ...space.files], options);

describe("help, version and usage errors", () => {
  test("--help prints the usage and loads no model", async () => {
    const { code, stdout, configs } = await run(["--help"]);
    assert.equal(code, 0);
    assert.match(stdout, /^Usage: oscars-remove-bg \[options\]/);
    for (const flag of [
      "--output",
      "--bg-image",
      "--shadow-opacity",
      "--json",
    ]) {
      assert.ok(stdout.includes(flag), flag);
    }
    assert.equal(configs.length, 0);
  });

  test("--version prints the version from package.json", async () => {
    const { code, stdout } = await run(["--version"]);
    assert.equal(code, 0);
    assert.equal(stdout, `${await readVersion()}\n`);
  });

  test("no inputs is a usage error", async () => {
    const { code, stderr } = await run([]);
    assert.equal(code, 2);
    assert.match(stderr, /No input files or folders/);
  });

  const BAD_FLAGS = [
    [["--bogus"], /--bogus/],
    [["--size", "huge"], /Invalid size "huge"/],
    [["--model", "huge"], /Unknown model "huge"/],
    [["--bg-image", "missing.png"], /Cannot read --bg-image/],
    [["--bg-color", "red", "--bg-image", "bg.png"], /only one bg_ parameter/],
  ];
  for (const [flags, message] of BAD_FLAGS) {
    test(`${flags.join(" ")} exits 2 before any model is created`, async () => {
      const { dir, files } = await workspace(["a.png"]);
      await writeFile(path.join(dir, "bg.png"), "bg");
      const result = await run([...flags, ...files], { cwd: dir });
      assert.equal(result.code, 2);
      assert.match(result.stderr, message);
      assert.equal(result.configs.length, 0);
    });
  }

  test("running the file directly reports version and usage errors", async () => {
    const ok = await execFileAsync(process.execPath, [CLI, "--version"]);
    assert.equal(ok.stdout, `${await readVersion()}\n`);
    await assert.rejects(execFileAsync(process.execPath, [CLI, "--bogus"]), {
      code: 2,
    });
  });
});

describe("inputs and output paths", () => {
  test("a folder keeps its name and structure under the output folder", async () => {
    const trip = ["Trip/beach.jpeg", "Trip/sub/city.png", "Trip/.hidden.png"];
    const { input, output } = await workspace([...trip, "Trip/notes.txt"]);
    const folder = path.join(input, "Trip");
    const { code, stdout } = await run(["-o", output, folder]);
    assert.equal(code, 0);
    assert.ok(await exists(path.join(output, "Trip", "beach.png")));
    assert.ok(await exists(path.join(output, "Trip", "sub", "city.png")));
    assert.ok(!(await exists(path.join(output, "Trip", ".hidden.png"))));
    assert.match(
      stdout,
      /^done Trip\/beach\.jpeg -> .*beach\.png \(40x30, \d+ ms\)$/m,
    );
    assert.match(stdout, /^2 done, 0 skipped, 0 failed in \d+\.\d s$/m);
  });

  test("the output folder defaults to ./removed-bg under the working directory", async () => {
    const { dir } = await workspace(["a.png"]);
    const { code } = await run(["in/a.png"], { cwd: dir });
    assert.equal(code, 0);
    assert.ok(await exists(path.join(dir, "removed-bg", "a.png")));
  });

  test("files already inside the output folder are not processed again", async () => {
    const { dir } = await workspace(["a.png"]);
    await mkdir(path.join(dir, "removed-bg"));
    await writeFile(path.join(dir, "removed-bg", "a.png"), "earlier result");
    const { code, stderr, calls } = await run(["."], { cwd: dir });
    assert.equal(code, 0);
    assert.equal(calls.length, 1);
    assert.match(stderr, /Ignoring 1 file\(s\) inside the output folder/);
  });

  test("a rejected input is reported while the others still run", async () => {
    const space = await workspace(["a.png", "notes.txt"]);
    const notes = path.join(space.input, "notes.txt");
    const args = ["-o", space.output, ...space.files, notes];
    const { code, stderr, calls } = await run(args);
    assert.equal(code, 0);
    assert.equal(calls.length, 1);
    assert.match(
      stderr,
      /1 image added, but 1 image could not be added because it is not a JPG\/PNG\/TIFF\/WEBP file\./,
    );
  });

  test("only rejected inputs leave nothing to do", async () => {
    const { input } = await workspace(["notes.txt"]);
    const notes = path.join(input, "notes.txt");
    const { code, stderr, configs } = await run([notes]);
    assert.equal(code, 2);
    assert.match(stderr, /Could not add 1 image because it is not a JPG/);
    assert.match(stderr, /No images to process/);
    assert.equal(configs.length, 0);
  });
});

describe("never overwriting", () => {
  test("an existing result is skipped untouched and not recomputed", async () => {
    const space = await workspace(["a.png", "b.png"], ["a.png"]);
    const { code, stdout, calls } = await runSpace(space);
    const target = path.join(space.output, "a.png");
    assert.equal(code, 0);
    assert.equal(await readFile(target, "utf8"), "keep:a.png");
    assert.equal(calls.length, 1);
    assert.ok(stdout.includes(`skipped (exists): ${target}\n`));
    assert.match(stdout, /^1 done, 1 skipped, 0 failed/m);
  });

  test("the skip check uses the normalized format (jpeg is jpg)", async () => {
    const space = await workspace(["a.png"], ["a.jpg"]);
    const { stdout, calls } = await runSpace(space, ["--format", "jpeg"]);
    assert.equal(calls.length, 0);
    assert.match(stdout, /skipped \(exists\)/);
  });

  test("with --format auto a result found at write time is not replaced", async () => {
    const space = await workspace(["a.png"], ["a.jpg"]);
    const { code, stdout, calls } = await runSpace(
      space,
      ["--format", "auto"],
      {
        respond: () => ({ format: "jpg" }),
      },
    );
    assert.equal(code, 0);
    assert.equal(calls.length, 1);
    const kept = await readFile(path.join(space.output, "a.jpg"), "utf8");
    assert.equal(kept, "keep:a.jpg");
    assert.match(stdout, /skipped \(exists\)/);
  });
});

describe("options reach the engine", () => {
  // [flag, engine key, value]; `true` is a switch without a value.
  const MAPPED = [
    ["--format", "format", "webp"],
    ["--size", "size", "preview"],
    ["--channels", "channels", "rgba"],
    ["--type", "type", "person"],
    ["--bg-color", "bg_color", "#336699"],
    ["--crop", "crop", true],
    ["--crop-margin", "crop_margin", "5%"],
    ["--scale", "scale", "50%"],
    ["--position", "position", "center"],
    ["--roi", "roi", "0 0 90% 90%"],
    ["--shadow", "shadow_type", "drop"],
    ["--shadow-opacity", "shadow_opacity", "40"],
  ];

  test("png is the default format", async () => {
    const { code, calls } = await runSpace(await workspace(["a.png"]));
    assert.equal(code, 0);
    assert.deepEqual(calls[0].options, { format: "png" });
  });

  test("flags map to the remove.bg-style keys", async () => {
    const flags = MAPPED.flatMap(([flag, , value]) =>
      value === true ? [flag] : [flag, value],
    );
    const expected = Object.fromEntries(MAPPED.map(([, key, v]) => [key, v]));
    const result = await runSpace(await workspace(["a.png"]), flags);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.calls[0].options, expected);
  });

  test("--bg-image is read once and passed as a Buffer", async () => {
    const space = await workspace(["a.png", "b.png"]);
    const image = path.join(space.dir, "bg.png");
    await writeFile(image, Buffer.from([1, 2, 3, 4]));
    const { code, calls } = await runSpace(space, ["--bg-image", image]);
    assert.equal(code, 0);
    assert.equal(calls.length, 2);
    assert.ok(Buffer.isBuffer(calls[0].options.bg_image));
    assert.deepEqual([...calls[0].options.bg_image], [1, 2, 3, 4]);
    assert.equal(calls[0].options.bg_image, calls[1].options.bg_image);
  });

  test("--format auto takes the extension from each result", async () => {
    const space = await workspace(["a.png", "b.png"]);
    const { code, calls } = await runSpace(space, ["--format", "auto"], {
      respond: (file) => ({ format: file.endsWith("a.png") ? "jpg" : "png" }),
    });
    assert.equal(code, 0);
    assert.equal(calls[0].options.format, "auto");
    assert.ok(await exists(path.join(space.output, "a.jpg")));
    assert.ok(await exists(path.join(space.output, "b.png")));
  });

  test("a matte is named after what the engine produced", async () => {
    const space = await workspace(["a.png"]);
    const flags = ["--channels", "alpha", "--format", "jpg"];
    const { code } = await runSpace(space, flags, {
      respond: () => ({ format: "png" }),
    });
    assert.equal(code, 0);
    assert.ok(await exists(path.join(space.output, "a.png")));
  });
});

describe("model selection", () => {
  const configFor = async (flags, env) => {
    const space = await workspace(["a.png"]);
    return (await runSpace(space, flags, { env, cwd: root })).configs[0];
  };

  test("quality names and exact ids choose the model", async () => {
    assert.equal((await configFor([])).modelId, "isnet-general-use");
    const best = await configFor(["--model", "best"]);
    assert.equal(best.modelId, "isnet-general-use");
    assert.equal((await configFor(["--model", "fast"])).modelId, "u2netp");
    const exact = await configFor(["--model", "u2net_human_seg"]);
    assert.equal(exact.modelId, "u2net_human_seg");
  });

  test("the models folder comes from --models-dir, then the environment", async () => {
    const env = { OSCARS_REMOVE_BG_MODELS: path.join(root, "models-env") };
    const fromEnv = await configFor([], env);
    assert.equal(fromEnv.modelDir, env.OSCARS_REMOVE_BG_MODELS);
    const flagged = await configFor(["--models-dir", "cache"], env);
    assert.equal(flagged.modelDir, path.join(root, "cache"));
  });
});

describe("processing and errors", () => {
  test("images are processed one at a time, in order", async () => {
    const space = await workspace(["a.png", "b.png", "c.png"]);
    const { code, calls, maxInFlight, disposed } = await runSpace(space);
    assert.equal(code, 0);
    assert.equal(maxInFlight, 1);
    const names = calls.map(({ file }) => path.basename(file));
    assert.deepEqual(names, ["a.png", "b.png", "c.png"]);
    assert.equal(disposed, 1);
  });

  test("a non-fatal error fails that image only", async () => {
    const space = await workspace(["a.png", "b.png", "c.png"]);
    const { code, stdout, stderr, calls } = await runSpace(space, [], {
      respond: failOn("b.png", unknownForeground),
    });
    assert.equal(code, 1);
    assert.equal(calls.length, 3);
    assert.ok(
      stderr.includes("error b.png: Could not identify foreground in image.\n"),
    );
    assert.ok(await exists(path.join(space.output, "a.png")));
    assert.ok(!(await exists(path.join(space.output, "b.png"))));
    assert.ok(await exists(path.join(space.output, "c.png")));
    assert.match(stdout, /^2 done, 0 skipped, 1 failed in /m);
  });

  test("a fatal error stops the run after the first image", async () => {
    const space = await workspace(["a.png", "b.png", "c.png"]);
    const { code, stdout, stderr, calls, disposed } = await runSpace(
      space,
      [],
      { respond: failOn("a.png", downloadFailed) },
    );
    assert.equal(code, 1);
    assert.equal(calls.length, 1);
    assert.match(stderr, /Could not download the background-removal model/);
    assert.match(stderr, /Stopped: 2 remaining image\(s\) not processed\./);
    assert.match(stdout, /^0 done, 0 skipped, 1 failed in /m);
    assert.equal(disposed, 1);
  });

  test("an output folder that cannot be created is reported per image", async () => {
    const space = await workspace(["a.png"]);
    const blocker = path.join(space.dir, "blocker");
    await writeFile(blocker, "a file, not a folder");
    const out = path.join(blocker, "out");
    const { code, stderr } = await run(["-o", out, ...space.files]);
    assert.equal(code, 1);
    assert.match(stderr, /^error a\.png: /m);
  });

  test("--quiet hides results but not errors", async () => {
    const space = await workspace(["a.png", "b.png"]);
    const { code, stdout, stderr } = await runSpace(space, ["-q"], {
      respond: failOn("b.png", unknownForeground),
    });
    assert.equal(code, 1);
    assert.equal(stdout, "");
    assert.match(stderr, /Could not identify foreground/);
  });
});

describe("model download progress", () => {
  test("prints one stderr line per 10%", async () => {
    const space = await workspace(["a.png"]);
    const { stderr } = await runSpace(space, [], { respond: reportDownload });
    const lines = stderr.trim().split("\n");
    const line = (percent, done) =>
      `Downloading model isnet-general-use: ${percent}% (${done} of 179 MB)`;
    assert.equal(lines.length, 10);
    assert.equal(lines[0], line(10, 18));
    assert.equal(lines[3], line(40, 71));
    assert.equal(lines[9], line(100, 179));
  });

  test("is silent with --quiet and --json", async () => {
    const space = await workspace(["a.png"]);
    for (const flag of ["--quiet", "--json"]) {
      const { stderr } = await runSpace(space, [flag], {
        respond: reportDownload,
      });
      assert.equal(stderr, "", flag);
    }
  });
});

describe("--json", () => {
  test("prints one parseable line per image and a summary", async () => {
    const names = ["a.png", "b.png", "c.png", "notes.txt"];
    const space = await workspace(names, ["c.png"]);
    const notes = path.join(space.input, "notes.txt");
    const { code, stdout, stderr } = await run(
      ["--json", "-o", space.output, ...space.files, notes],
      { respond: failOn("b.png", unknownForeground) },
    );
    assert.equal(code, 1);
    const lines = stdout
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const [done, failed, skipped, { summary }] = lines;
    assert.equal(lines.length, 4);

    assert.equal(done.status, "done");
    assert.equal(done.input, path.join(space.input, "a.png"));
    assert.equal(done.output, path.join(space.output, "a.png"));
    assert.deepEqual(
      [done.width, done.height, done.format, done.error],
      [40, 30, "png", null],
    );
    assert.ok(Number.isInteger(done.ms));
    assert.equal(failed.status, "error");
    assert.equal(failed.error, "Could not identify foreground in image.");
    assert.equal(failed.width, null);
    assert.equal(skipped.status, "skipped");
    assert.equal(skipped.output, path.join(space.output, "c.png"));

    const { ms, ...counts } = summary;
    assert.ok(Number.isInteger(ms));
    assert.deepEqual(counts, {
      done: 1,
      skipped: 1,
      failed: 1,
      notProcessed: 0,
      rejected: 1,
    });
    // The rejection notice stays off the JSON stream.
    assert.match(stderr, /could not be added/);
  });
});
