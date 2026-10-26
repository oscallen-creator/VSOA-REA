import { after, describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { HISTORY_LIMIT, loadHistory } from "../src/main/history.js";

const dirs = [];
const historyFile = async (contents) => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "whisper-history-"));
  dirs.push(dir);
  const file = path.join(dir, "history.json");
  if (contents !== undefined) await writeFile(file, contents);
  return file;
};
after(() =>
  Promise.all(dirs.map((dir) => rm(dir, { recursive: true, force: true }))),
);

describe("loadHistory", () => {
  test("starts empty without a file, keeps the newest first and survives a reload", async () => {
    const file = await historyFile();
    const history = await loadHistory(file);
    assert.deepEqual(history.entries, []);
    await history.add("first", 1);
    await history.add("second", 2);
    const expected = [
      { text: "second", at: 2 },
      { text: "first", at: 1 },
    ];
    assert.deepEqual(history.entries, expected);
    assert.deepEqual((await loadHistory(file)).entries, expected);
  });

  test(`keeps only the latest ${HISTORY_LIMIT}`, async () => {
    const history = await loadHistory(await historyFile());
    for (let i = 0; i <= HISTORY_LIMIT; i++) await history.add(`n${i}`, i);
    assert.equal(history.entries.length, HISTORY_LIMIT);
    assert.equal(history.entries[0].text, `n${HISTORY_LIMIT}`);
    assert.equal(history.entries.at(-1).text, "n1");
  });

  test("clear empties the file too", async () => {
    const file = await historyFile();
    const history = await loadHistory(file);
    await history.add("secret", 1);
    await history.clear();
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), []);
  });

  test("skips malformed entries, and warns about an unreadable file without its contents", async () => {
    const good = { text: "ok", at: 5 };
    const mixed = await historyFile(
      JSON.stringify([good, { text: 3 }, null, { at: 1 }]),
    );
    assert.deepEqual((await loadHistory(mixed)).entries, [good]);
    const warnings = [];
    const broken = await historyFile("my private words");
    const history = await loadHistory(broken, {
      warn: (message) => warnings.push(message),
    });
    assert.deepEqual(history.entries, []);
    assert.equal(warnings.length, 1);
    assert.doesNotMatch(warnings[0], /private/);
  });
});
