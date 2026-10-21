import { afterEach, beforeEach, describe, mock, test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  PALETTE,
  SHADOW_DEFAULT_OPACITY,
  applySettingsPatch,
  createSettingsStore,
  defaultSettings,
  sanitizeSettings,
} from "../src/main/settings.js";

const PICTURES = path.join(path.sep, "home", "oscar", "Pictures");
const DEFAULTS = defaultSettings({ picturesDir: PICTURES });

const patchOf = (current, patch) => applySettingsPatch(current, patch);

const storeAt = (file, defaults = DEFAULTS) =>
  createSettingsStore({ file, defaults });

let dir;
beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), "orbg-settings-"));
});
afterEach(async () => {
  mock.restoreAll();
  await rm(dir, { recursive: true, force: true });
});

describe("defaultSettings", () => {
  test("matches remove.bg desktop's defaults under <Pictures>", () => {
    assert.deepEqual(DEFAULTS, {
      outputPath: path.join(PICTURES, "Oscar's Remove BG"),
      usePsd: false,
      shadow: "none",
      shadowOpacity: "none",
      bgMode: "transparent",
      bgColor: "#FFFFFF",
      size: "auto",
      quality: "best",
    });
  });

  test("returns a fresh object each time", () => {
    const a = defaultSettings({ picturesDir: PICTURES });
    a.usePsd = true;
    assert.equal(defaultSettings({ picturesDir: PICTURES }).usePsd, false);
  });
});

describe("constants", () => {
  test("PALETTE holds ten unique uppercase #RRGGBB colors", () => {
    assert.equal(PALETTE.length, 10);
    assert.equal(new Set(PALETTE).size, 10);
    for (const color of PALETTE) assert.match(color, /^#[0-9A-F]{6}$/);
  });

  test("PALETTE and SHADOW_DEFAULT_OPACITY are frozen", () => {
    assert.ok(Object.isFrozen(PALETTE));
    assert.ok(Object.isFrozen(SHADOW_DEFAULT_OPACITY));
  });

  test("every palette color survives sanitizing unchanged", () => {
    for (const color of PALETTE) {
      assert.deepEqual(sanitizeSettings({ bgColor: color }), {
        bgColor: color,
      });
    }
  });

  test("each shadow has the documented default opacity", () => {
    assert.deepEqual(
      { ...SHADOW_DEFAULT_OPACITY },
      { none: "none", auto: "auto", car: 90, "3D": 50, drop: 50 },
    );
  });
});

describe("sanitizeSettings", () => {
  test("keeps every valid known key", () => {
    const valid = {
      outputPath: path.join(PICTURES, "out"),
      usePsd: true,
      shadow: "3D",
      shadowOpacity: 40,
      bgMode: "color",
      bgColor: "#123ABC",
      size: "preview",
      quality: "fast",
    };
    assert.deepEqual(sanitizeSettings(valid), valid);
  });

  test("returns an empty object for non-object patches", () => {
    for (const patch of [undefined, null, "shadow", 42, true]) {
      assert.deepEqual(sanitizeSettings(patch), {});
    }
  });

  test("drops unknown keys and does not read inherited ones", () => {
    const patch = Object.create({ quality: "fast" });
    patch.unknown = 1;
    assert.deepEqual(sanitizeSettings(patch), {});
  });

  test("drops outputPath unless it is an absolute string", () => {
    assert.deepEqual(sanitizeSettings({ outputPath: "relative/dir" }), {});
    assert.deepEqual(sanitizeSettings({ outputPath: "" }), {});
    assert.deepEqual(sanitizeSettings({ outputPath: 7 }), {});
    assert.deepEqual(sanitizeSettings({ outputPath: null }), {});
  });

  test("usePsd must be a real boolean", () => {
    assert.deepEqual(sanitizeSettings({ usePsd: false }), { usePsd: false });
    for (const usePsd of ["true", 1, 0, null]) {
      assert.deepEqual(sanitizeSettings({ usePsd }), {});
    }
  });

  test("accepts exactly the listed shadows (case-sensitive)", () => {
    for (const shadow of ["none", "auto", "car", "3D", "drop"]) {
      assert.deepEqual(sanitizeSettings({ shadow }), { shadow });
    }
    for (const shadow of ["3d", "Drop", "bogus", "", null, 3]) {
      assert.deepEqual(sanitizeSettings({ shadow }), {});
    }
  });

  test("shadowOpacity accepts none, auto and integers 0..100", () => {
    for (const shadowOpacity of ["none", "auto", 0, 1, 50, 100]) {
      assert.deepEqual(sanitizeSettings({ shadowOpacity }), { shadowOpacity });
    }
    const invalid = [-1, 101, 1.5, NaN, Infinity, "50", "", null, true, {}];
    for (const shadowOpacity of invalid) {
      assert.deepEqual(sanitizeSettings({ shadowOpacity }), {});
    }
  });
});

describe("sanitizeSettings colors, sizes and modes", () => {
  test("bgMode accepts transparent and color only", () => {
    assert.deepEqual(sanitizeSettings({ bgMode: "color" }), {
      bgMode: "color",
    });
    for (const bgMode of ["image", "Color", "", null]) {
      assert.deepEqual(sanitizeSettings({ bgMode }), {});
    }
  });

  test("bgColor is stored uppercase and must be #RRGGBB", () => {
    assert.deepEqual(sanitizeSettings({ bgColor: "#abcdef" }), {
      bgColor: "#ABCDEF",
    });
    assert.deepEqual(sanitizeSettings({ bgColor: "#aBc123" }), {
      bgColor: "#ABC123",
    });
    const invalid = [
      "#fff",
      "FFFFFF",
      "#GGGGGG",
      "#FFFFFFF",
      "#FFFFFFFF",
      "#FFFFFF\n",
      " #FFFFFF",
      "rgb(0,0,0)",
      "",
      0xffffff,
      null,
    ];
    for (const bgColor of invalid) {
      assert.deepEqual(sanitizeSettings({ bgColor }), {}, String(bgColor));
    }
  });

  test("size accepts auto, preview and full; legacy 50MP becomes full", () => {
    for (const size of ["auto", "preview", "full"]) {
      assert.deepEqual(sanitizeSettings({ size }), { size });
    }
    assert.deepEqual(sanitizeSettings({ size: "50MP" }), { size: "full" });
    for (const size of ["50mp", "Full", "medium", "", null, 50]) {
      assert.deepEqual(sanitizeSettings({ size }), {});
    }
  });

  test("quality accepts best and fast only", () => {
    assert.deepEqual(sanitizeSettings({ quality: "fast" }), {
      quality: "fast",
    });
    for (const quality of ["Best", "medium", "", null]) {
      assert.deepEqual(sanitizeSettings({ quality }), {});
    }
  });

  test("keeps valid keys when sibling keys are invalid", () => {
    assert.deepEqual(
      sanitizeSettings({ quality: "fast", size: "huge", usePsd: "yes" }),
      { quality: "fast" },
    );
  });

  test("does not mutate its input", () => {
    const patch = Object.freeze({ bgColor: "#abcdef", size: "50MP" });
    assert.deepEqual(sanitizeSettings(patch), {
      bgColor: "#ABCDEF",
      size: "full",
    });
    assert.deepEqual({ ...patch }, { bgColor: "#abcdef", size: "50MP" });
  });
});

describe("applySettingsPatch", () => {
  test("merges valid keys over the current settings", () => {
    const next = patchOf(DEFAULTS, { quality: "fast", usePsd: true });
    assert.deepEqual(next, { ...DEFAULTS, quality: "fast", usePsd: true });
  });

  test("ignores invalid values and leaves the current ones", () => {
    assert.deepEqual(patchOf(DEFAULTS, { size: "huge", quality: 3 }), DEFAULTS);
  });

  test("never mutates the current settings", () => {
    const current = Object.freeze({ ...DEFAULTS });
    const next = patchOf(current, { shadow: "car" });
    assert.notEqual(next, current);
    assert.equal(current.shadow, "none");
  });

  test("choosing a shadow resets opacity to that shadow's default", () => {
    const expected = {
      none: "none",
      auto: "auto",
      car: 90,
      "3D": 50,
      drop: 50,
    };
    for (const [shadow, opacity] of Object.entries(expected)) {
      const from = { ...DEFAULTS, shadow: "drop", shadowOpacity: 17 };
      const next = patchOf(from, { shadow });
      assert.equal(next.shadow, shadow);
      assert.equal(next.shadowOpacity, opacity, shadow);
    }
  });

  test("choosing the same shadow again resets a customised opacity", () => {
    const from = { ...DEFAULTS, shadow: "car", shadowOpacity: 20 };
    assert.equal(patchOf(from, { shadow: "car" }).shadowOpacity, 90);
  });

  test("an opacity in the same patch overrides the shadow default", () => {
    const next = patchOf(DEFAULTS, { shadow: "car", shadowOpacity: 25 });
    assert.deepEqual([next.shadow, next.shadowOpacity], ["car", 25]);
  });

  test("opacity 0 and 100 are kept, not treated as missing", () => {
    assert.equal(
      patchOf(DEFAULTS, { shadow: "drop", shadowOpacity: 0 }).shadowOpacity,
      0,
    );
    assert.equal(
      patchOf(DEFAULTS, { shadow: "drop", shadowOpacity: 100 }).shadowOpacity,
      100,
    );
  });

  test("an invalid shadow in the patch changes neither shadow nor opacity", () => {
    const from = { ...DEFAULTS, shadow: "drop", shadowOpacity: 30 };
    const next = patchOf(from, { shadow: "bogus" });
    assert.deepEqual([next.shadow, next.shadowOpacity], ["drop", 30]);
  });

  test("an opacity-only patch updates the current shadow's opacity", () => {
    const from = { ...DEFAULTS, shadow: "3D", shadowOpacity: 50 };
    assert.equal(patchOf(from, { shadowOpacity: 75 }).shadowOpacity, 75);
  });

  test("shadow none forces opacity none, even if the patch sets a number", () => {
    const withNone = patchOf(DEFAULTS, { shadow: "none", shadowOpacity: 40 });
    assert.equal(withNone.shadowOpacity, "none");
    const from = { ...DEFAULTS, shadow: "none" };
    assert.equal(patchOf(from, { shadowOpacity: 40 }).shadowOpacity, "none");
    assert.equal(
      patchOf(from, { shadowOpacity: "auto" }).shadowOpacity,
      "none",
    );
  });

  test("auto opacity is only valid with shadow auto", () => {
    const from = { ...DEFAULTS, shadow: "car", shadowOpacity: 30 };
    assert.equal(patchOf(from, { shadowOpacity: "auto" }).shadowOpacity, 90);
    const drop = patchOf(DEFAULTS, { shadow: "drop", shadowOpacity: "auto" });
    assert.equal(drop.shadowOpacity, 50);
    const auto = patchOf(DEFAULTS, { shadow: "auto", shadowOpacity: "auto" });
    assert.equal(auto.shadowOpacity, "auto");
  });

  test("shadow auto accepts an explicit numeric opacity", () => {
    const next = patchOf(DEFAULTS, { shadow: "auto", shadowOpacity: 60 });
    assert.deepEqual([next.shadow, next.shadowOpacity], ["auto", 60]);
  });

  test("an explicit none opacity under a real shadow is kept as written", () => {
    const from = { ...DEFAULTS, shadow: "car", shadowOpacity: 90 };
    assert.equal(
      patchOf(from, { shadowOpacity: "none" }).shadowOpacity,
      "none",
    );
  });
});

describe("createSettingsStore", () => {
  test("get() returns the defaults before load()", () => {
    assert.deepEqual(storeAt(path.join(dir, "s.json")).get(), DEFAULTS);
  });

  test("a missing file loads defaults without warning", async () => {
    const warn = mock.method(console, "warn", () => {});
    const store = storeAt(path.join(dir, "missing.json"));
    assert.deepEqual(await store.load(), DEFAULTS);
    assert.deepEqual(store.get(), DEFAULTS);
    assert.equal(warn.mock.callCount(), 0);
  });

  test("a corrupt file loads defaults and warns", async () => {
    const warn = mock.method(console, "warn", () => {});
    const file = path.join(dir, "s.json");
    await writeFile(file, "{ not json");
    const store = storeAt(file);
    assert.deepEqual(await store.load(), DEFAULTS);
    assert.equal(warn.mock.callCount(), 1);
    assert.match(String(warn.mock.calls[0].arguments[0]), /s\.json/);
  });

  test("an empty file loads defaults", async () => {
    mock.method(console, "warn", () => {});
    const file = path.join(dir, "s.json");
    await writeFile(file, "");
    assert.deepEqual(await storeAt(file).load(), DEFAULTS);
  });

  test("valid JSON that is not an object loads defaults", async () => {
    const file = path.join(dir, "s.json");
    for (const text of ["null", "[]", '"text"', "42", "true"]) {
      await writeFile(file, text);
      assert.deepEqual(await storeAt(file).load(), DEFAULTS, text);
    }
  });

  test("a failed load after a good one resets to defaults", async () => {
    mock.method(console, "warn", () => {});
    const file = path.join(dir, "s.json");
    await writeFile(file, JSON.stringify({ quality: "fast" }));
    const store = storeAt(file);
    assert.equal((await store.load()).quality, "fast");
    await writeFile(file, "garbage");
    assert.deepEqual(await store.load(), DEFAULTS);
  });

  test("load() merges saved valid values over defaults and drops the rest", async () => {
    const file = path.join(dir, "s.json");
    await writeFile(
      file,
      JSON.stringify({
        quality: "fast",
        size: "50MP",
        bgColor: "#abcdef",
        usePsd: "yes",
        outputPath: "relative",
        shadowOpacity: 500,
        stale: true,
      }),
    );
    const loaded = await storeAt(file).load();
    assert.deepEqual(loaded, {
      ...DEFAULTS,
      quality: "fast",
      size: "full",
      bgColor: "#ABCDEF",
    });
    assert.equal(Object.hasOwn(loaded, "stale"), false);
  });

  test("does not mutate the defaults it was given", async () => {
    const defaults = Object.freeze({ ...DEFAULTS });
    const file = path.join(dir, "s.json");
    const store = storeAt(file, defaults);
    await store.update({ quality: "fast" });
    assert.equal(defaults.quality, "best");
    assert.equal(store.get().quality, "fast");
  });
});

describe("createSettingsStore saving", () => {
  test("update() applies the patch, returns and persists the result", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    const next = await store.update({ shadow: "car", bgMode: "color" });
    assert.equal(next.shadowOpacity, 90);
    assert.deepEqual(store.get(), next);
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), next);
  });

  test("a second store loads what the first saved", async () => {
    const file = path.join(dir, "s.json");
    const first = storeAt(file);
    await first.update({ shadow: "drop", shadowOpacity: 10, usePsd: true });
    const second = storeAt(file);
    assert.deepEqual(await second.load(), first.get());
  });

  test("update() applies the shadow rules before saving", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    await store.update({ shadow: "3D" });
    await store.update({ shadow: "none" });
    const saved = JSON.parse(await readFile(file, "utf8"));
    assert.deepEqual([saved.shadow, saved.shadowOpacity], ["none", "none"]);
  });

  test("update() with only invalid values still saves valid settings", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    await store.update({ quality: "bogus" });
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), DEFAULTS);
  });

  test("save creates missing parent directories", async () => {
    const file = path.join(dir, "a", "b", "settings.json");
    await storeAt(file).update({ quality: "fast" });
    assert.equal(JSON.parse(await readFile(file, "utf8")).quality, "fast");
  });

  test("saving is atomic: no temporary files are left behind", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    await store.update({ quality: "fast" });
    await store.update({ quality: "best" });
    assert.deepEqual(await readdir(dir), ["s.json"]);
  });

  test("a failed save leaves no temporary file behind", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    await store.update({ quality: "fast" });
    // A directory at the destination makes the final rename fail.
    await rm(file);
    await mkdir(file);
    await assert.rejects(store.update({ quality: "best" }));
    const leftovers = (await readdir(dir)).filter((name) =>
      name.endsWith(".tmp"),
    );
    assert.deepEqual(leftovers, []);
  });

  test("concurrent updates all resolve and the last patch wins on disk", async () => {
    const file = path.join(dir, "s.json");
    const store = storeAt(file);
    const patches = [
      { quality: "fast" },
      { usePsd: true },
      { bgMode: "color" },
      { size: "full" },
      { bgColor: "#000000" },
    ];
    await Promise.all(patches.map((patch) => store.update(patch)));
    const expected = Object.assign({}, DEFAULTS, ...patches);
    assert.deepEqual(store.get(), expected);
    assert.deepEqual(JSON.parse(await readFile(file, "utf8")), expected);
  });

  test("load() restores shadow and opacity as a consistent pair", async () => {
    const file = path.join(dir, "s.json");
    await writeFile(
      file,
      JSON.stringify({ shadow: "car", shadowOpacity: "auto" }),
    );
    const loaded = await storeAt(file).load();
    assert.notEqual(loaded.shadowOpacity, "auto");
    await writeFile(
      file,
      JSON.stringify({ shadow: "none", shadowOpacity: 40 }),
    );
    assert.equal((await storeAt(file).load()).shadowOpacity, "none");
  });
});
