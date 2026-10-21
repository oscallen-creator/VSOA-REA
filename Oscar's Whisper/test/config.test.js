import { after, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { loadConfig } from "../src/main/config.js";

const dirs = [];
const makeUserDataDir = async (contents) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "whisper-config-"));
  dirs.push(dir);
  if (contents !== undefined)
    await writeFile(path.join(dir, "config.json"), contents);
  return dir;
};
after(() =>
  Promise.all(dirs.map((dir) => rm(dir, { recursive: true, force: true }))),
);

const DEFAULTS = {
  shortcuts: {},
  pasteDelayMs: 50,
  restoreClipboardDelayMs: 600,
};

describe("loadConfig", () => {
  test("returns the defaults and the file path when there is no config file", async () => {
    const userDataDir = await makeUserDataDir();
    assert.deepEqual(await loadConfig({ userDataDir }), {
      ...DEFAULTS,
      file: path.join(userDataDir, "config.json"),
    });
  });

  test("lets known keys in the file override the defaults", async () => {
    const values = {
      shortcuts: { "ctrl+win": "ptt" },
      pasteDelayMs: 10,
      restoreClipboardDelayMs: 1_000,
    };
    const userDataDir = await makeUserDataDir(JSON.stringify(values));
    assert.deepEqual(await loadConfig({ userDataDir }), {
      ...values,
      file: path.join(userDataDir, "config.json"),
    });
  });

  test("keeps the defaults for keys the file leaves out", async () => {
    const userDataDir = await makeUserDataDir('{"pasteDelayMs": 5}');
    const config = await loadConfig({ userDataDir });
    assert.deepEqual(
      [config.shortcuts, config.pasteDelayMs, config.restoreClipboardDelayMs],
      [{}, 5, 600],
    );
  });

  test("drops unknown keys such as an old API key", async () => {
    const userDataDir = await makeUserDataDir(
      JSON.stringify({ apiKey: "secret", pasteDelayMs: 5, extra: true }),
    );
    const config = await loadConfig({ userDataDir });
    assert.deepEqual(Object.keys(config).sort(), [
      "file",
      "pasteDelayMs",
      "restoreClipboardDelayMs",
      "shortcuts",
    ]);
    assert.ok(!JSON.stringify(config).includes("secret"));
  });

  test("keeps the default and warns for a value of the wrong type", async () => {
    const userDataDir = await makeUserDataDir(
      JSON.stringify({
        shortcuts: { "ctrl+win": 1 },
        pasteDelayMs: "abc",
        restoreClipboardDelayMs: -5,
      }),
    );
    const warnings = [];
    const config = await loadConfig({
      userDataDir,
      warn: (message) => warnings.push(message),
    });
    assert.deepEqual(config, {
      ...DEFAULTS,
      file: path.join(userDataDir, "config.json"),
    });
    assert.equal(warnings.length, 3);
    for (const key of ["shortcuts", "pasteDelayMs", "restoreClipboardDelayMs"])
      assert.ok(warnings.some((warning) => warning.includes(`"${key}"`)));
  });

  test("falls back to the defaults when the JSON is not an object", async () => {
    for (const contents of [
      "[]",
      '["pasteDelayMs"]',
      "5",
      "null",
      '"text"',
      "true",
    ]) {
      const userDataDir = await makeUserDataDir(contents);
      assert.deepEqual(await loadConfig({ userDataDir }), {
        ...DEFAULTS,
        file: path.join(userDataDir, "config.json"),
      });
    }
  });

  test("rejects invalid JSON naming the file, with the parse error as cause", async () => {
    const userDataDir = await makeUserDataDir("{ not json");
    const file = path.join(userDataDir, "config.json");
    const error = await loadConfig({ userDataDir }).catch((caught) => caught);
    assert.match(error.message, /^Could not read /);
    assert.ok(error.message.includes(file));
    assert.ok(error.cause instanceof SyntaxError);
  });

  test("rejects when the config file cannot be read for a reason other than being absent", async () => {
    const userDataDir = await makeUserDataDir();
    await mkdir(path.join(userDataDir, "config.json"));
    const error = await loadConfig({ userDataDir }).catch((caught) => caught);
    assert.match(error.message, /^Could not read /);
    assert.equal(error.cause.code, "EISDIR");
  });
});
