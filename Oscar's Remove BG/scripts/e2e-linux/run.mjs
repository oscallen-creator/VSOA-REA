// End-to-end test of the real app on Linux under Xvfb, driven by Playwright.
// It clicks through the window like a person would and checks the files the
// app writes. Native file dialogs are replaced from the test, because a
// virtual display has nobody to click them.
//
//   npm i --no-save playwright-core@1.56.1        (once, in this project)
//   OSCARS_REMOVE_BG_MODELS=/path/with/isnet-general-use.onnx \
//     xvfb-run -a node scripts/e2e-linux/run.mjs <folder with test photos>
//
// The photos folder needs at least three JPEG/PNG photos with a clear subject.
// Screenshots and a report go to $E2E_OUT (default: a temp folder).

import assert from "node:assert/strict";
import { cp, mkdir, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);
const require = createRequire(path.join(projectDir, "package.json"));
const { _electron: electron } = require("playwright-core");
const sharp = require("sharp");
const { initializeCanvas, readPsd } = require("ag-psd");

const photosDir = path.resolve(process.argv[2] ?? "");
const outDir =
  process.env.E2E_OUT ?? (await mkdtemp(path.join(os.tmpdir(), "orbg-e2e-")));
const home = await mkdtemp(path.join(os.tmpdir(), "orbg-home-"));
const results = [];

const scenario = async (name, run) => {
  const started = Date.now();
  try {
    await run();
    results.push({ name, ok: true, ms: Date.now() - started });
    console.log(`PASS ${name}`);
  } catch (error) {
    results.push({ name, ok: false, error: error.stack });
    console.log(`FAIL ${name}\n${error.stack}`);
  }
};

const launch = async () => {
  const app = await electron.launch({
    executablePath: path.join(
      projectDir,
      "node_modules/electron/dist/electron",
    ),
    args: ["--no-sandbox", projectDir],
    env: {
      ...process.env,
      HOME: home,
      XDG_CONFIG_HOME: path.join(home, ".config"),
    },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(error.message));
  await page.waitForSelector("#add");
  return { app, page, errors };
};

// The picker is files-only in the app; the stub can still hand it a folder,
// which goes through the same path as a dropped folder.
const stubPicker = (app, filePaths) =>
  app.evaluate(({ dialog }, paths) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: paths });
  }, filePaths);

const state = (page) => page.evaluate(() => window.removeBg.getState());
const rowStatuses = async (page) =>
  (await state(page)).queue.rows.map((row) => row.status);

const waitForStatus = (page, pattern, timeout = 300_000) =>
  page.waitForFunction(
    (source) =>
      new RegExp(source).test(
        document.querySelector("#status-text")?.textContent ?? "",
      ),
    pattern.source,
    { timeout },
  );

const dismissAlert = async (page) => {
  const dialog = page.locator("#alert[open]");
  if (await dialog.count()) {
    const text = await page.locator("#alert-message").textContent();
    await page.click("#alert-ok");
    return text;
  }
  return null;
};

const shoot = (page, name) =>
  page.screenshot({ path: path.join(outDir, `${name}.png`) });

const listFiles = async (dir) => {
  const found = [];
  const walk = async (folder, prefix) => {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(path.join(folder, entry.name), rel);
      else found.push(rel);
    }
  };
  await walk(dir, "");
  return found.sort();
};

const prepareInputs = async () => {
  const photos = (await readdir(photosDir))
    .filter((name) => /\.(jpe?g|png)$/i.test(name))
    .slice(0, 3);
  assert.ok(photos.length >= 3, "need at least three photos");
  const inputs = path.join(home, "inputs");
  await mkdir(path.join(inputs, "Trip"), { recursive: true });
  await cp(
    path.join(photosDir, photos[0]),
    path.join(inputs, "Trip", photos[0]),
  );
  await cp(
    path.join(photosDir, photos[1]),
    path.join(inputs, "Trip", photos[1]),
  );
  await cp(
    path.join(photosDir, photos[1]),
    path.join(inputs, "Trip", `.hidden-${photos[1]}`),
  );
  await writeFile(path.join(inputs, "Trip", "notes.txt"), "not an image");
  await cp(path.join(photosDir, photos[2]), path.join(inputs, photos[2]));
  return {
    pick: [path.join(inputs, "Trip"), path.join(inputs, photos[2])],
    names: photos,
  };
};

// Read from the app: Electron resolves the Pictures folder itself.
let outputRoot = null;
const stem = (name) => name.replace(/\.[^.]+$/, "");

const runAll = async (page) => {
  await page.click("#start");
  await waitForStatus(page, /^Finished/);
};

const freshList = async (app, page, pick) => {
  if (await page.isEnabled("#clear")) await page.click("#clear");
  await stubPicker(app, pick);
  await page.click("#add");
  await page.waitForFunction(
    () => document.querySelectorAll("#rows tr").length > 0,
  );
  return dismissAlert(page);
};

// Each runs in order on one app session and leaves it ready for the next.
const SCENARIOS = [
  [
    "window opens on the empty state",
    async ({ page }) => {
      assert.equal(await page.title(), "Oscar's Remove BG");
      assert.ok(await page.isVisible("#empty"));
      await shoot(page, "01-empty");
    },
  ],
  [
    "adding a folder keeps structure and reports rejects",
    async ({ app, page, inputs }) => {
      const message = await freshList(app, page, inputs.pick);
      assert.match(
        message ?? "",
        /3 images added, but 1 image could not be added because it is not a JPG\/PNG\/TIFF\/WEBP file\./,
      );
      const rows = (await state(page)).queue.rows
        .map((row) => row.relativePath)
        .sort();
      assert.deepEqual(
        rows,
        [
          ...inputs.names.slice(0, 2).map((n) => `Trip/${n}`),
          inputs.names[2],
        ].sort(),
      );
      await shoot(page, "02-added");
    },
  ],
  [
    "transparent run writes PNG cutouts",
    async ({ page, expected }) => {
      await runAll(page);
      assert.deepEqual(await rowStatuses(page), [
        "finished",
        "finished",
        "finished",
      ]);
      const files = await listFiles(outputRoot);
      assert.deepEqual(
        files,
        expected.map((name) => `${name}.png`),
      );
      for (const file of files) {
        const meta = await sharp(path.join(outputRoot, file)).metadata();
        assert.equal(meta.hasAlpha, true, file);
      }
      await shoot(page, "03-finished-transparent");
    },
  ],
  [
    "second run skips existing outputs",
    async ({ app, page, inputs }) => {
      await freshList(app, page, inputs.pick);
      await runAll(page);
      assert.deepEqual(await rowStatuses(page), [
        "skipped",
        "skipped",
        "skipped",
      ]);
      const text = await page.locator("#rows").textContent();
      assert.match(text, /Skipped: File already exists/);
      await shoot(page, "04-skipped");
    },
  ],
  [
    "colored background with a drop shadow writes JPEGs",
    async ({ app, page, inputs, expected }) => {
      await page.click('[data-bg="color"]');
      await page.fill("#color-hex", "#2BB0CA");
      await page.press("#color-hex", "Enter");
      await page.selectOption("#shadow", "drop");
      await freshList(app, page, inputs.pick);
      const settings = (await state(page)).settings;
      assert.equal(settings.bgMode, "color");
      assert.equal(settings.bgColor, "#2BB0CA");
      assert.equal(settings.shadowOpacity, 50);
      await runAll(page);
      assert.deepEqual(await rowStatuses(page), [
        "finished",
        "finished",
        "finished",
      ]);
      const jpg = path.join(outputRoot, `${expected[0]}.jpg`);
      const { data, info } = await sharp(jpg)
        .raw()
        .toBuffer({ resolveWithObject: true });
      const corner = [...data.subarray(0, 3)];
      assert.ok(
        info.channels === 3 &&
          corner.every((v, i) => Math.abs(v - [0x2b, 0xb0, 0xca][i]) <= 6),
        `corner ${corner}`,
      );
      await shoot(page, "05-colored");
    },
  ],
  [
    "Photoshop file writes layered PSDs",
    async ({ app, page, inputs, expected }) => {
      await page.click('[data-bg="transparent"]');
      await page.check("#use-psd");
      await freshList(app, page, inputs.pick);
      await runAll(page);
      initializeCanvas(
        () => {
          throw new Error("no canvas");
        },
        (w, h) => ({
          width: w,
          height: h,
          data: new Uint8ClampedArray(w * h * 4),
        }),
      );
      const psd = readPsd(
        await import("node:fs/promises").then(({ readFile }) =>
          readFile(path.join(outputRoot, `${expected[0]}.psd`)),
        ),
        { useImageData: true },
      );
      const names = psd.children.map((layer) => layer.name);
      assert.deepEqual(names, [
        "Oscar's Remove BG - Original Image",
        "Oscar's Remove BG - Shadows",
        "Oscar's Remove BG",
      ]);
      assert.ok(psd.children.at(-1).mask, "cutout has a layer mask");
      await shoot(page, "06-psd");
    },
  ],
  [
    "cancel stops after the current image",
    async ({ app, page, inputs }) => {
      await page.uncheck("#use-psd");
      await page.selectOption("#shadow", "none");
      await page.selectOption("#size", "preview");
      // A fresh output folder (through the Change link) so nothing is skipped.
      const fresh = path.join(home, "cancel-out");
      await stubPicker(app, [fresh]);
      await page.click("#change-output");
      await page.waitForFunction(
        (folder) =>
          document.querySelector("#open-output")?.textContent.includes(folder),
        fresh,
      );
      assert.equal((await state(page)).settings.outputPath, fresh);
      await freshList(app, page, inputs.pick);
      await page.click("#start");
      await page.locator("#cancel").waitFor({ state: "visible" });
      await page.click("#cancel");
      await waitForStatus(page, /^Finished/);
      const statuses = await rowStatuses(page);
      assert.ok(
        statuses.includes("ready"),
        `some rows left ready: ${statuses}`,
      );
      assert.ok(
        statuses.filter((s) => s === "finished").length <= 1,
        `${statuses}`,
      );
      // The Start button must stay readable under the mouse.
      await page.hover("#start");
      const colors = await page.$eval("#start", (button) => {
        const style = getComputedStyle(button);
        return [style.color, style.backgroundColor];
      });
      assert.notEqual(colors[0], colors[1], `hovered Start: ${colors}`);
      await shoot(page, "07-cancelled");
    },
  ],
];

const main = async () => {
  const inputs = await prepareInputs();
  const expected = [
    `Trip/${stem(inputs.names[0])}`,
    `Trip/${stem(inputs.names[1])}`,
    stem(inputs.names[2]),
  ].sort();
  let session = await launch();
  const { app, page } = session;
  const context = { app, page, inputs, expected };
  outputRoot = (await state(page)).settings.outputPath;
  assert.ok(
    outputRoot.startsWith(home),
    `output inside the test home: ${outputRoot}`,
  );
  for (const [name, run] of SCENARIOS) {
    await scenario(name, () => run(context));
  }

  await scenario("no console errors in the window", async () => {
    assert.deepEqual(session.errors, []);
  });

  await app.close();

  await scenario("settings survive a restart", async () => {
    session = await launch();
    const settings = (await state(session.page)).settings;
    assert.equal(settings.bgColor, "#2BB0CA");
    assert.equal(settings.size, "preview");
    assert.equal(settings.bgMode, "transparent");
    await session.app.close();
  });

  await writeFile(
    path.join(outDir, "report.json"),
    JSON.stringify(results, null, 2),
  );
  const failed = results.filter((result) => !result.ok).length;
  console.log(
    `\n${results.length - failed} passed, ${failed} failed. Screenshots: ${outDir}`,
  );
  process.exit(failed ? 1 : 0);
};

await main();
