# Oscar's Remove BG: handoff

This is for the next person or agent picking this up. It covers what the
project is, where every piece lives, the exact contracts between pieces, how
to rebuild the working environment from nothing, what has been verified, and
a prioritized checklist of edge cases still to test.

For install and everyday use, see [README.md](README.md).

> **Keep this file current.** When you change behavior, update the matching
> section here in the same commit.

## 0. Status at a glance

| Area                                    | State                                                                | Where                                       |
| --------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------- |
| REA analysis of remove.bg desktop 3.0.0 | Done. Findings summarized in section 1                               | This file                                   |
| Collector script (Windows)              | Done. Worked on the owner's PC under Windows PowerShell 5.1          | `scripts/collect-removebg.ps1`              |
| Engine: options, models, segmentation   | Done and tested. Masks match rembg 2.0.67 at IoU 0.982–0.999         | `src/engine/`                               |
| Engine: compositing, zip, PSD output    | Done and tested                                                      | `src/engine/compose.js`, `zip.js`, `psd.js` |
| Engine: local shadows, DPI, JPEG 0.92   | Done and tested; shadows checked by eye on sample photos             | `src/engine/shadow.js`, `compose.js`        |
| Command-line tool                       | Done and tested, also run on real photos                             | `src/cli.js`                                |
| App main process, queue, settings       | Done and unit-tested                                                 | `src/main/`                                 |
| Engine utility process                  | Done. Fixed a crash on the second IS-Net image (section 9)           | `src/main/engineHost.js`                    |
| Window UI (renderer)                    | Done. Exercised by the end-to-end test; screenshots reviewed         | `src/renderer/`                             |
| End-to-end test of the real app         | Done: 9/9 scenarios pass on Linux under Xvfb with the real models    | `scripts/e2e-linux/run.mjs`                 |
| Real Windows / macOS run                | **NOT DONE**. Nothing has run on the owner's PC except the collector | Section 11                                  |
| Installer / packaging                   | Not started                                                          | Section 12                                  |

Branch: `claude/zealous-wright-2cb3aq` on `oscallen-creator/VSOA-REA`. All
project files live in the `Oscar's Remove BG/` folder at the repo root (the
apostrophe and space are intentional; quote the path in every shell).

## 1. What remove.bg desktop actually does (the spec we copied)

Analyzed build: **remove.bg 3.0.0** by Canva Austria GmbH, installed at
`%LOCALAPPDATA%\remove\app-3.0.0` (Squirrel install). Main exe
`removebg-desktop.exe`, SHA-256
`B53A968C38C851FBC6159B8021B837603669094B479700CB7023C08B890C35A6`.
Electron 44.4.5, Vite build, Vue 2 UI. Own code: `.vite/build/main.js`
(127 KB), `.vite/build/preload.js`, `.vite/renderer/main_window/assets/index-b1bd8fdc.js`
(3.7 MB, mostly libraries; the app's code is the last ~34,000 lines after
REA/Wakaru recovery, around recovered lines 366,900–400,830).

Evidence pointers below like `R:L367135` are line numbers in the
**REA-recovered** renderer (`recover-javascript-sources` output,
`modules/bundle.js`); `M:L9685` is the recovered main bundle. Those files were
in the analysis sandbox only (see 1.6 to regenerate). No remove.bg code is in
this repository.

### 1.1 The processing pipeline (all server-side except recombining)

1. Inputs: drag and drop (folders walked recursively, names starting with `.`
   skipped, dropped folder's own name kept in the relative path) or a flat
   file picker. Accepted by MIME type: `image/jpeg`, `image/png`,
   `image/tiff`, `image/webp`. Max **22 MiB** per file. Duplicates rejected
   by absolute path. One summary modal for rejections (R:L398971–399014).
2. Before upload every image is drawn on a **white** canvas, capped at
   **50,000,000 px** (scaled by `sqrt(50e6/px)`), and re-encoded as **JPEG
   quality 0.92** (R:L51026–51064). TIFF is decoded with tiff.js first.
3. `POST https://api.remove.bg/v1.0/removebg` (multipart): `image_file`,
   `size` (`auto` | `preview` | `full` | `50MP`), `format` (`zip`, or
   `zip_layers` when the PSD preference is on), `shadow_type`
   (`none|auto|car|3D|drop`), `shadow_opacity`, `bg_color` (`#RRGGBB`, only
   in colored mode and not PSD). Auth: `X-Api-Key` and/or
   `Authorization: Bearer` (R:L367135–367290).
4. Response: a ZIP with `color.jpg` + `alpha.png` (optional
   `shadow_color.jpg`, `shadow_alpha.png`, `semi_transparency_*`). Response
   headers `x-width`, `x-height`, `x-credits-charged`, `x-type`.
5. The client recombines (`ZipCanvas`, R:L51071–51364): alpha.png's R channel
   becomes the alpha of color.jpg on a canvas → exported as PNG (transparent)
   or JPEG 0.92 (colored). **Cutout, shadow and background color are made by
   the server.** Canvas export means fully transparent pixels come out RGB 0.
6. PSD (transparent mode + "Photoshop file"): built locally with ag-psd. Layers
   bottom→top: `remove.bg - Original Image` (hidden), `remove.bg - Semi
   Transparency`, `remove.bg - Shadows` (black fill, mask = shadow alpha, fill
   opacity), `remove.bg - Background` (dead code in practice), `remove.bg`
   (color raster with the alpha as an editable layer mask). DPI in resource 1005.
7. DPI: read from the input (sharp metadata via IPC, EXIF fallback, TIFF tags)
   and written back with `sharp(...).withMetadata({ density })`
   (M:L9685–9694). **Bug**: only JPEG and TIFF inputs carry it; PNG/WebP lose it.
8. Output path: `<outputPath>/<relative path>` with the last extension
   replaced by `png` / `jpg` / `psd`. **Never overwrites**: if the target
   exists the row shows `Skipped: File already exists` before any upload
   (R:L367138–367144, R:L399212–399214).

### 1.2 Settings (electron-settings, R:L394397–394539)

| Key                | Default                | Values                                             |
| ------------------ | ---------------------- | -------------------------------------------------- |
| `outputPath`       | `<Pictures>/remove.bg` | folder                                             |
| `usePsd`           | `false`                | boolean (only offered in transparent mode)         |
| `shadow`           | `"none"`               | `none`, `auto`, `car`, `3D`, `drop`                |
| `shadow_opacity`   | `"none"`               | `none`, `auto` (only with auto), 10..100, `custom` |
| `bgMode`           | `"transparent"`        | `transparent`, `color`, `design`                   |
| `bgColor`          | `"#FFFFFF"`            | `#RRGGBB`; 10-color palette                        |
| `size`             | `"auto"`               | `auto`, `preview`, `50MP` (UI "Full Size")         |
| `selectedDesignId` | `0`                    | design template id                                 |

Shadow defaults when chosen: car 90, drop 50, 3D 50, auto "Mixed"
(car 90 / other 50 from the `x-type` header). API key and OAuth token live in
the OS keychain (keytar service `remove.bg`, accounts `default`, `authToken`).

### 1.3 Queue and UI

- better-queue, `batchSize: 5`, `concurrent: 1`, no retries: up to 5 images
  in parallel with a barrier between batches.
- Row states: ready, processing, waiting (429), finished, error. App states:
  ready, processing, stopping, finished.
- Cancel stops starting new work; in-flight uploads finish (and are charged).
- Fatal errors (`auth_failed`, `insufficient_credits`, `save_error`,
  `reduce_error`, `output_dir_not_writable`, …) show a modal and reset the
  app to ready; **bug**: the failed batch never completes, so the rest of the
  queue stalls.
- Layout: toolbar (+, drag hint, cog) → File|Output table with dashed empty
  state → options (background buttons, Shadow/Opacity, Photoshop file, color
  picker + 10 presets, Output size, Output folder) → Clear list / Start /
  Cancel → status bar ("N files, Transparent bg, Output format: png",
  "Processing i of N file(s) (P %)", "Finished m of N file(s) | …").
- Window 800x600; no menu on Windows/Linux.

### 1.4 Things it does that we deliberately did not copy

| Original behavior                                                                                                                                                          | Why not                                                   |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Uploads every image to remove.bg, needs credits                                                                                                                            | The point of the remake: local, free, offline after setup |
| Design Templates download `global.js` and run it via `vm.runInThisContext`                                                                                                 | Remote code execution; server-only feature                |
| Login (OAuth via accounts.kaleido.ai), API key, credits, version kill switch, auto-update feed                                                                             | Account/server features                                   |
| Preload exposes generic `writeFileSync`/`readFileSync`/`fsMkdirSync` to the page with no sender checks (REA: 3 bridged APIs, 26 members, 0 sender-validation observations) | Security: our page gets only named actions                |
| 429 retry reads `headers["retry-after"]` on a `Headers` object → NaN → instant infinite retry                                                                              | Bug                                                       |
| Fatal error stalls the queue                                                                                                                                               | Bug                                                       |
| PNG/WebP inputs lose DPI                                                                                                                                                   | Bug                                                       |
| A failed credit fetch deletes the stored API key                                                                                                                           | Bug (and we have no key)                                  |
| `zip_layers` requested whenever the PSD preference is on, even for JPG                                                                                                     | Bug                                                       |

### 1.5 What could not be determined

Server behavior: the matting model, how `size` maps to megapixels and
credits, the AI shadow renderer, what `x-type` can contain. The design
template scripts. These are why our shadows are approximations (section 10).

### 1.6 How to regenerate the analysis

1. On the Windows PC (no admin needed): download and run the collector.
   This is exactly what worked (Windows PowerShell 5.1; pin to a commit so
   GitHub's raw cache cannot serve a stale copy):
   ```powershell
   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
   $ps1 = Join-Path $env:TEMP "collect-removebg.ps1"
   Invoke-WebRequest -UseBasicParsing -OutFile $ps1 -Uri "https://raw.githubusercontent.com/oscallen-creator/VSOA-REA/<commit>/Oscar's%20Remove%20BG/scripts/collect-removebg.ps1"
   powershell -NoProfile -ExecutionPolicy Bypass -File $ps1
   ```
   It writes `removebg-for-rea.zip` (1.4 MB for 3.0.0: 170 files) to the
   Desktop: `app/` = the app's own files from `app.asar` (dependencies only
   as `package.json`), `install/` = small loose files, `_rea/` =
   `manifest.json`, `inventory.csv` (every install file with size, SHA-256,
   version info), `asar-index.csv` (all 5,783 asar entries). It never reads
   `%APPDATA%`.
2. Drag the zip into the chat; in the cloud session it appears under
   `/root/.claude/uploads/<session>/`. Extract it into its own empty folder.
3. Run REA (see section 6 for setup):
   ```bash
   export REA_WAKARU_COMMAND=/path/to/wakaru   # Wakaru 1.14.0 linux-x64
   node scripts/rea.mjs recover-javascript-sources <app>/.vite/build/main.js <out>/recovered-main --format json
   node scripts/rea.mjs recover-javascript-sources <app>/.vite/renderer/main_window/assets/index-b1bd8fdc.js <out>/recovered-renderer --format json
   node scripts/rea.mjs analyze-javascript-application <app> --artifact-format directory \
     --source-path .vite/build/main.js --source-path .vite/build/preload.js --source-path package.json \
     --format json --full-output > main-analysis.json
   ```
   Recovery took about 1 s (main) and 42 s (renderer). The whole-app
   `analyze-javascript-application` hits its 300 s per-source limit on the
   3.7 MB renderer and returns `provider_timeout` with partial evidence; that
   is why only main/preload were analyzed as a graph.

## 2. Architecture

```
renderer (src/renderer, sandboxed page, no Node)
   │  window.removeBg.*  (src/preload/index.cjs, contextBridge, CommonJS)
   ▼
main process (src/main/index.js)
   ├─ settings.js     JSON settings in <userData>/settings.json
   ├─ inputs.js       dropped/picked paths → queue entries (+ rejection text)
   ├─ queue.js        rows + run state machine; maps settings → engine options
   ├─ outputPath.js   <outputPath>/<relative path>.<png|jpg|psd>
   └─ engineClient.js utilityProcess.fork(engineHost.js), request/response by id
                         │  postMessage { type: "process", id, sourcePath, resultPath, options, quality }
                         ▼
      engine utility process (src/main/engineHost.js)
         ├─ removeBackground.js  decode → segment → compose
         │    ├─ options.js      remove.bg-style options → normalized object
         │    ├─ models.js / modelStore.js  pinned ONNX models, download + SHA-256
         │    ├─ segment.js      onnxruntime-node inference, rembg-equivalent pre/post
         │    ├─ compose.js      ROI, crop, scale/position, size cap, shadow, background, encode
         │    ├─ shadow.js       local drop / contact shadows
         │    ├─ psd.js          layered PSD (ag-psd)
         │    └─ zip.js          color.jpg + alpha.png STORE zip
         ├─ writeNew.js          exclusive-create write ("wx"), never overwrites
         └─ engineErrors.js      error → { code, message, fatal }

CLI (src/cli.js) uses the same engine, inputs.js, outputPath.js, writeNew.js
and engineErrors.js directly, without Electron.
```

Why a utility process: decoding, inference and pixel loops would freeze the
window if run in the main process, and a crash (for example out of memory on a
huge image) only kills the engine. `engineClient.js` then fails pending jobs as
fatal and the next Start forks a fresh process.

## 3. File map

| Path                             | Responsibility                                                                                                                                                                                                                                                                                                                                            | Key exports                                                                                                                                               |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `package.json`                   | ESM, Node ≥ 22. Deps pinned exactly: `sharp@0.35.5`, `onnxruntime-node@1.30.0`, `ag-psd@31.0.3`; dev `electron@44.9.2`. Scripts `start`, `cli`, `test`. `bin: oscars-remove-bg`                                                                                                                                                                           | —                                                                                                                                                         |
| `scripts/collect-removebg.ps1`   | Windows collector (section 1.6). Parses `app.asar` itself (JavaScriptSerializer on 5.1, `ConvertFrom-Json -AsHashtable` on 7), splits zips over `-MaxZipMB`                                                                                                                                                                                               | —                                                                                                                                                         |
| `src/engine/options.js`          | Parses remove.bg API parameters (camelCase or snake_case, strings or values) into one frozen normalized object (section 4.1). Throws `OptionError` (`code: "invalid_option"`, `parameter`)                                                                                                                                                                | `parseOptions`, `OptionError`, `parseColor`, `parseLength`, `parseMargin`, `parsePosition`, `parseScale`, `parseRoi`                                      |
| `src/engine/models.js`           | Model registry (section 5)                                                                                                                                                                                                                                                                                                                                | `MODELS`, `DEFAULT_MODEL_ID`, `getModel`                                                                                                                  |
| `src/engine/modelStore.js`       | Download on first use, verify size + SHA-256, `.verified` sidecar to skip re-hashing, atomic rename, shared in-flight downloads, abort                                                                                                                                                                                                                    | `ensureModel`, `defaultModelDir`, `modelPath`, `ModelDownloadError`                                                                                       |
| `src/engine/segment.js`          | ONNX inference. Lanczos resize to the model's square input, divide by brightest value, mean/std normalize (CHW), min-max scale the first output, truncate to 8 bit, Lanczos back. Runs serialized                                                                                                                                                         | `createSegmenter`, `toInputTensor`, `toMask`                                                                                                              |
| `src/engine/compose.js`          | ROI → subject box (alpha ≥ 10) → crop/scale/position plan → size cap (preview 250,000 px, full 50 MP) → PSD branch (layers kept apart) or shadow under the cutout → background color/image → channels → encode png/jpg/webp/zip. JPEG quality 92; png/webp get RGB 0 under alpha 0; `density` written with sharp `withDensity`                            | `compose`, `ForegroundError`, `applyRoi`, `findSubjectBox`, `scanSubjectBox`, `planGeometry`, `fitToMaxPixels`, `SUBJECT_ALPHA_THRESHOLD`, `JPEG_QUALITY` |
| `src/engine/shadow.js`           | Local shadows from the canvas alpha: `drop` = silhouette blurred (σ 1.5 % of the longer box side) and offset (2 %, 3 %) down-right; `car` / `3D` / `auto` = silhouette squashed to 6 / 12 / 8 % of the box height under its base, blurred σ 2 / 4 / 3 % of the box width. Blur only on a tile around the shadow; `minAmplitude` 0.01 so tails are not cut | `renderShadow` (async), `SHADOW_STYLES`                                                                                                                   |
| `src/engine/psd.js`              | Layered PSD (section 1.1 item 6, with our names). Refuses canvases under 3 px wide (ag-psd 31.0.3 truncates them)                                                                                                                                                                                                                                         | `encodePsd`, `LAYER_NAMES`, `MAX_PSD_SIZE`, `MIN_PSD_WIDTH`                                                                                               |
| `src/engine/zip.js`              | Minimal STORE zip writer (`zlib.crc32`, fixed 1980 timestamps)                                                                                                                                                                                                                                                                                            | `createZip`                                                                                                                                               |
| `src/engine/removeBackground.js` | Decode (sharp: EXIF rotate, flatten on white, sRGB, 8-bit, cap 50 MP with orientation-aware exact fit) → segment → compose; lazy model load with retry                                                                                                                                                                                                    | `createRemover`, `decodeImage`, `fitArea`, `MAX_INPUT_PIXELS`                                                                                             |
| `src/cli.js`                     | Batch CLI (section 8)                                                                                                                                                                                                                                                                                                                                     | `main`                                                                                                                                                    |
| `src/main/index.js`              | App lifecycle, single-instance lock, window (900x680, sandboxed, CSP in page, navigation blocked, permissions denied), IPC handlers with sender check                                                                                                                                                                                                     | —                                                                                                                                                         |
| `src/main/settings.js`           | Settings defaults and validation, shadow/opacity rules, serialized atomic saves                                                                                                                                                                                                                                                                           | `createSettingsStore`, `defaultSettings`, `applySettingsPatch`, `sanitizeSettings`, `PALETTE`, `SHADOW_DEFAULT_OPACITY`, enums                            |
| `src/main/inputs.js`             | Path expansion and acceptance rules (section 4.4)                                                                                                                                                                                                                                                                                                         | `collectInputs`, `describeRejections`, `isInsideFolder`, `IMAGE_EXTENSIONS`, `MAX_INPUT_BYTES`, `Rejection`                                               |
| `src/main/outputPath.js`         | Format by mode, result path rule                                                                                                                                                                                                                                                                                                                          | `outputFormat`, `resultPath`                                                                                                                              |
| `src/main/queue.js`              | Rows and run state machine (section 4.3); settings → engine options                                                                                                                                                                                                                                                                                       | `createQueue`, `engineOptions`, `RowStatus`, `AppStatus`, `SKIPPED_MESSAGE`                                                                               |
| `src/main/engineClient.js`       | Forks and talks to the utility process; fails pending jobs as fatal if it exits                                                                                                                                                                                                                                                                           | `createEngineClient` → `{ run, dispose }`                                                                                                                 |
| `src/main/engineHost.js`         | Utility-process entry. One remover (model) in memory at a time, keyed by quality. Writes the output itself                                                                                                                                                                                                                                                | — (side-effect module; do not import in tests)                                                                                                            |
| `src/main/engineErrors.js`       | Error classification (section 4.5)                                                                                                                                                                                                                                                                                                                        | `classifyError`                                                                                                                                           |
| `src/main/writeNew.js`           | `mkdir -p` + `writeFile(..., { flag: "wx" })`, removes its own half-written file, tags failures `stage: "write"`                                                                                                                                                                                                                                          | `writeNewFile`                                                                                                                                            |
| `src/preload/index.cjs`          | `window.removeBg` bridge (section 4.2). Must stay CommonJS (sandboxed preload)                                                                                                                                                                                                                                                                            | —                                                                                                                                                         |
| `src/renderer/index.html`        | Page skeleton, CSP (`default-src 'self'`, no inline script), inline SVG icon sprite, `<dialog id="alert">`, `<template id="row-template">`                                                                                                                                                                                                                | —                                                                                                                                                         |
| `src/renderer/app.js`            | State, subscriptions, drag and drop (always `preventDefault`), button and option wiring; all IPC through `window.removeBg`                                                                                                                                                                                                                                | —                                                                                                                                                         |
| `src/renderer/view.js`           | Status-bar texts, keyed row rendering (text only via `textContent`), option rendering incl. shadow/opacity rules (duplicates `SHADOW_DEFAULT_OPACITY`: the sandboxed page cannot import main code), alert queue                                                                                                                                           | —                                                                                                                                                         |
| `src/renderer/app.css`           | Light/dark (`prefers-color-scheme`) via CSS variables, checkerboard swatches                                                                                                                                                                                                                                                                              | —                                                                                                                                                         |
| `scripts/e2e-linux/run.mjs`      | End-to-end test (section 7.3)                                                                                                                                                                                                                                                                                                                             | —                                                                                                                                                         |
| `test/*.test.js`                 | `node:test` suites (section 7)                                                                                                                                                                                                                                                                                                                            | —                                                                                                                                                         |

## 4. Contracts

### 4.1 Normalized engine options (`parseOptions` → `compose`)

```js
{
  size: "preview" | "full" | "auto",                 // aliases: small/regular → preview; medium/hd/4k → full
  format: "auto" | "png" | "jpg" | "webp" | "zip" | "psd",   // "jpeg" → "jpg"
  channels: "rgba" | "alpha",
  type: "auto" | "person" | "product",               // car/animal/graphic/transportation → auto; currently advisory only
  bgColor: null | { r, g, b, alpha },                // from hex (3/4/6/8 digits, # optional) or a CSS name
  bgImage: null | Buffer,                            // not decoded until compose
  crop: boolean,
  cropMargin: { top, right, bottom, left },          // each { value, unit: "px" | "%" }; CSS 1/2/4-value shorthand
  scale: null | number,                              // 0.1..1 ("10%".."100%"); null = original
  position: null | { x, y },                         // 0..1; defaults to center when scale is set
  roi: null | [x1, y1, x2, y2],                      // each { value, unit }
  shadowType: "none" | "auto" | "car" | "3D" | "drop", // from shadow_type; "3d" accepted
  shadowOpacity: number,                             // 0..1, resolved: none 0, drop .5, 3D .5, car .9, auto .5
}
```

Rules worth knowing: `bg_color` + `bg_image` together throws; unknown keys
throw; percent crop margins are relative to the subject box and each side is
capped at min(50 % of the subject side, 500 px) inside `compose`; with `crop`
the scale/position options are ignored; `format: "auto"` = PNG if any pixel
is translucent, else JPEG (a shadow makes it PNG unless a background is set);
`channels: "alpha"` + `format: "zip"` throws; `format: "psd"` + `bg_image`
throws (PSD takes a colour background only); `channels: "alpha"` with psd
returns the PNG matte.

### 4.2 IPC (preload `window.removeBg` → `ipcMain.handle` in `src/main/index.js`)

| Preload method                                               | Channel                          | Returns                                                                                    |
| ------------------------------------------------------------ | -------------------------------- | ------------------------------------------------------------------------------------------ |
| `getState()`                                                 | `app:state`                      | `{ queue, settings, model, palette, platform, version }`                                   |
| `updateSettings(patch)`                                      | `settings:update`                | full settings after rules (re-render from this)                                            |
| `addFiles(fileList)`                                         | `inputs:add`                     | `{ added, message }`; paths come from `webUtils.getPathForFile` in the preload             |
| `pickFiles()`                                                | `inputs:pick`                    | same; native multi-select dialog filtered to the image extensions                          |
| `pickOutputFolder()`                                         | `output:pick`                    | settings                                                                                   |
| `start()` / `cancel()` / `clear()` / `remove(id)`            | `queue:*`                        | start → boolean                                                                            |
| `openResult(id)` / `showInFolder(id)` / `openOutputFolder()` | `open:*`                         | paths are looked up in main from row ids and settings; the page never sends a path to open |
| `onQueue(cb)` / `onModel(cb)` / `onAlert(cb)`                | pushes `queue`, `model`, `alert` | unsubscribe function                                                                       |

Every handler rejects calls whose `event.senderFrame.url` is not the app's
own `index.html` file URL.

### 4.3 Queue snapshot (`queue` push and `getState().queue`)

```js
{
  status: "ready" | "processing" | "stopping" | "finished",
  rows: [{ id, name, relativePath, sourcePath,
           status: "ready" | "processing" | "finished" | "skipped" | "error",
           message,                        // "" | error text | "Skipped: File already exists"
           output: null | { path, format, width, height, bgMode, bgColor, skipped? } }],
  run: null | { total, done, bgMode, format },
}
```

- Settings are snapshotted at Start; changing them mid-run does not affect
  the run.
- One image at a time (the model already uses every core). remove.bg ran 5
  uploads in parallel because the work was remote.
- Skip check happens before the engine is called, and again at write time
  (`"wx"`), so a file appearing mid-run is still never overwritten.
- Fatal error: the row goes back to `ready` with the message, the app goes to
  `ready`, one alert is sent, remaining rows stay `ready`; Start retries them.
- Snapshots and `findRow` return copies.

### 4.4 Input rules (`collectInputs(paths, known, { outputFolder })`)

Order per file: inside `outputFolder` → `inside_output`; extension not in
`.jpg .jpeg .png .tif .tiff .webp` (case-insensitive) → `wrong_type`; larger
than 200 MB → `too_large` (remove.bg's 22 MB was an upload limit); already
known → `already_added`; stat failure → `unreadable`. Names starting with "."
are skipped silently (top level and inside folders). Folder entries are
sorted with `localeCompare`. `describeRejections` reproduces remove.bg's
sentence ("2 images added, but 1 image could not be added because it is not a
JPG/PNG/TIFF/WEBP file.").

### 4.5 Error classification (`classifyError`)

| Condition                                                    | code                                | fatal | Message                                                                                                      |
| ------------------------------------------------------------ | ----------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------ |
| `name === "ModelDownloadError"`                              | `model_unavailable`                 | yes   | "Could not download the background-removal model (…). Check your internet connection and press Start again." |
| write stage + EACCES / EPERM / EROFS                         | `output_dir_not_writable`           | yes   | "Output folder is not writable. Please change output folder." (remove.bg's text)                             |
| write stage + ENOSPC                                         | `disk_full`                         | yes   | "The disk is full."                                                                                          |
| `code === "unknown_foreground"` (ForegroundError)            | `unknown_foreground`                | no    | "Could not identify foreground in image." (remove.bg API's error)                                            |
| message matches unsupported format / corrupt / premature end | `load_image_error`                  | no    | "Could not read this image: …"                                                                               |
| engine process exited                                        | —                                   | yes   | "The image engine stopped unexpectedly (exit code N)."                                                       |
| anything else                                                | its `code` or `process_image_error` | no    | its message                                                                                                  |

## 5. Models

| id                  | Use                | Input | Normalization     | Bytes       | SHA-256                                                            | License                        |
| ------------------- | ------------------ | ----- | ----------------- | ----------- | ------------------------------------------------------------------ | ------------------------------ |
| `isnet-general-use` | default ("Best")   | 1024² | mean 0.5, std 1   | 178,648,008 | `60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a` | Apache-2.0 (xuebinqin/DIS)     |
| `u2netp`            | "Fast"             | 320²  | ImageNet mean/std | 4,574,861   | `309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8` | Apache-2.0 (xuebinqin/U-2-Net) |
| `u2net_human_seg`   | CLI `--model` only | 320²  | ImageNet mean/std | 175,997,641 | `01eb6a29a5c4d8edb30b56adad9bb3a2a0535338e480724a213e0acfd2d1c73c` | Apache-2.0                     |

URLs: `https://github.com/danielgatis/rembg/releases/download/v0.0.0/<id>.onnx`.
Cache: `OSCARS_REMOVE_BG_MODELS` if set; Windows
`%LOCALAPPDATA%\Oscar's Remove BG\models`; macOS
`~/Library/Application Support/Oscar's Remove BG/models`; Linux
`${XDG_CACHE_HOME:-~/.cache}/oscars-remove-bg/models`. Models are never
committed.

## 6. Rebuilding the environment (fresh cloud container)

```bash
# 1. Pinned Node (the image ships 22.x; the repo pins 24.18.0)
cd /tmp && curl -fsSLO https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz
curl -fsSL https://nodejs.org/dist/v24.18.0/SHASUMS256.txt | grep 'linux-x64.tar.xz$' | sha256sum -c -
tar -xJf node-v24.18.0-linux-x64.tar.xz -C /usr/local --strip-components=1
export PATH=/usr/local/bin:$PATH && npm i -g npm@11.16.0

# 2. REA itself (repo root) — only needed to re-run the analysis
cd /home/user/VSOA-REA && npm ci && npm run build:cached

# 3. The project. On Linux x64 onnxruntime-node's install script tries to fetch
#    CUDA binaries from api.nuget.org, which the sandbox blocks; skip them.
#    (Windows and macOS need nothing: their binaries are bundled.)
cd "/home/user/VSOA-REA/Oscar's Remove BG" && ONNXRUNTIME_NODE_INSTALL=skip npm install

# 4. Models for tests and manual runs (or let the app download them)
mkdir -p /tmp/models && for m in u2netp isnet-general-use; do
  curl -fsSL -o /tmp/models/$m.onnx https://github.com/danielgatis/rembg/releases/download/v0.0.0/$m.onnx; done
export OSCARS_REMOVE_BG_MODELS=/tmp/models

# 5. Optional tools
#    - PowerShell 7.4 / 6.0.5 tarballs from github.com/PowerShell/PowerShell releases
#      to test the collector (6.0.5 reproduces Windows PowerShell 5.1's parser errors;
#      it needs "System.Globalization.Invariant": true in pwsh.runtimeconfig.json)
#    - Wakaru 1.14.0: github.com/pionxzh/wakaru/releases/download/v1.14.0/wakaru-linux-x64.tar.gz
#    - rembg reference: python3 -m venv venv && venv/bin/pip install "rembg[cpu]==2.0.67"
#    - Xvfb is preinstalled (xvfb-run); Playwright: npm i playwright-core@1.56.1 in a scratch dir
```

The repo's git hooks run `oxfmt` and `oxlint --fix` on staged files
(pre-commit) and REA's `check:fast` (pre-push). Lint limits that bite here:
500 lines per file (`max-lines`, warning) and 100 lines per function
(`max-lines-per-function`); `.cjs` files need an
`oxlint-disable-next-line typescript/no-var-requires` for `require`.

## 7. Tests

### 7.1 Unit tests

Run: `cd "Oscar's Remove BG" && npm test` (Node's runner, `test/*.test.js`).
With `OSCARS_REMOVE_BG_MODELS` pointing at a folder containing `u2netp.onnx`,
the real-model tests run too (otherwise they are skipped, not failed).

| Files                                                                  | Covers                                                                                                                           |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `options*.test.js`                                                     | every option, alias, error, defaults, freezing                                                                                   |
| `modelStore.test.js`                                                   | local HTTP server: download, verify, sidecar, mismatch, size guard, 404, abort, concurrency, progress, dirs                      |
| `segment.test.js`                                                      | tensor layout/normalization, mask scaling (truncation), fake runtime, serialization, 1-channel masks, real u2netp                |
| `compose*.test.js`, `zip.test.js`                                      | ROI, crop/margins/caps, scale/position, preview cap, colors, image backdrop, alpha matte, encodings, zip round-trip with `unzip` |
| `shadow.test.js`, `compose.shadow.test.js`, `compose.encoding.test.js` | shadow geometry/opacity/clipping, shadow under the cutout, DPI, zeroed RGB under alpha 0, JPEG 92                                |
| `psd.test.js`, `compose.psd.test.js`                                   | read-back with ag-psd: layer order, masks, composite, DPI, limits; PSD through `compose`                                         |
| `removeBackground.test.js`                                             | decode (EXIF 3/6/8, 16-bit, CMYK, gray, alpha, density, size cap, corrupt, bomb), remover lifecycle                              |
| `settings.test.js`, `inputs.test.js`, `outputPath.test.js`             | section 4.4 rules, settings rules, concurrent saves                                                                              |
| `queue*.test.js`                                                       | run state machine, skip, fatal, cancel, snapshots, option mapping                                                                |
| `engineErrors.test.js`                                                 | section 4.5                                                                                                                      |
| `cli.test.js`                                                          | flags, exit codes, folder structure, skip, JSON output, fatal/non-fatal (fake remover)                                           |

Last full run: **562 tests, 562 pass** with `OSCARS_REMOVE_BG_MODELS` set
(without it: 555 tests, 554 pass, 1 skipped; the model-only suites are not counted). `compose.helpers.test.js` and
`options.helpers.test.js` hold shared fixtures only (named `*.test.js` so the
glob includes them; each reports as one passing entry).

### 7.2 Manual and parity checks already done

- **Mask parity with rembg 2.0.67** (same models, four photos from rembg's
  `examples/`: animal-1, car-1, food-1 at 6000x4000, girl-1): mean absolute
  difference 0.06–0.65 of 255, IoU at 128 = 0.982–0.999. The residue is at
  edges (PIL vs libvips Lanczos). Script idea: run `rembg.remove(...,
  only_mask=True)` and `createSegmenter().segment()` on the same decoded
  image, compare.
- **Pipeline smoke test** (isnet, 4 vCPU, 15 GB container): 2.5–5.5 s per
  image including PNG encode; first image +5 s for model load. u2netp: 0.2–0.6 s.
- **Visual check**: cutouts of tiger, person, car + pedestrian over a
  checkerboard looked clean.
- **Electron**: the engine runs in Electron 44.9.2's utility process (after
  the arena fix in section 9: four images in a row including 6000x4000).
- **CLI**: folder with a subfolder and a `.txt`: structure kept, rejection
  sentence printed, colored JPEG run, exit 0.
- **Collector**: PowerShell 7.4 against a synthetic `@electron/asar` app
  (byte-identical extraction, unpacked files, case-only duplicates, symlink
  skip, size limits, dependency filtering, multi-part zips); PowerShell 6.0.5
  parser check; and the real run on the owner's PC (5.1.26100).

### 7.3 End-to-end test (real app, Linux)

```bash
cd "Oscar's Remove BG"
ONNXRUNTIME_NODE_INSTALL=skip npm i --no-save playwright-core@1.56.1
OSCARS_REMOVE_BG_MODELS=/tmp/models E2E_OUT=/tmp/e2e-out \
  xvfb-run -a -s "-screen 0 1280x900x24" node scripts/e2e-linux/run.mjs <folder with ≥ 3 photos>
```

It launches the real app (`_electron.launch`) with a throw-away `HOME`, and
replaces `dialog.showOpenDialog` from the test (a folder path works through
the stub, which exercises folder walking). Scenarios, all passing (times with
isnet on 4 vCPUs; photos animal-1, car-1 and food-1 at 6000x4000):

| Scenario                                                                                                  | Time   |
| --------------------------------------------------------------------------------------------------------- | ------ |
| Window opens on the empty state                                                                           | 0.1 s  |
| Folder add keeps `Trip/…`, rejects `notes.txt` with remove.bg's sentence, skips a dot-file                | 0.3 s  |
| Transparent run: 3 PNGs with alpha at the expected paths                                                  | 8.5 s  |
| Second run: every row "Skipped: File already exists"                                                      | 0.3 s  |
| Colored #2BB0CA + Drop Shadow: settings applied, JPEG corner colour within ±6                             | 9.0 s  |
| Photoshop file: PSD layers Original Image / Shadows / Oscar's Remove BG, mask present                     | 16.6 s |
| Change output folder via the Change link, Start, Cancel: ≤ 1 finished, rest ready; hovered Start readable | 2.2 s  |
| No console errors in the window                                                                           | —      |
| Settings survive a restart                                                                                | 0.6 s  |

Screenshots (`01-empty.png` … `07-cancelled.png`) and `report.json` go to
`E2E_OUT`. Not covered: a real OS drag and drop (only the picker path), the
native dialogs themselves, the model download inside the app (models are
pre-cached), a crash of the engine process.

## 8. Command line

`npm run cli -- [options] <file-or-folder>...` or `node src/cli.js …`.
Defaults: output `./removed-bg`, format png, model best. Flags map 1:1 to
section 4.1 (`--bg-color`, `--bg-image`, `--crop`, `--crop-margin`,
`--scale`, `--position`, `--roi`, `--channels`, `--type`, `--size`,
`--format`, `--shadow`, `--shadow-opacity`, `--model best|fast|<id>`,
`--models-dir`, `--json`, `--quiet`). Exit 0 all done/skipped, 1 any failure
or fatal stop, 2 usage error (validated before the model loads). Files inside
the output folder are rejected (`inside_output`).

## 9. Bugs found and fixed so far

| Bug                                                                                                        | Found by                    | Fix                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Collector failed to parse on Windows PowerShell 5.1 (`if` as a `;`-separated hashtable value)              | Owner's run                 | Values computed outside the literal; checked with the PS 6.0.5 parser                                                                                                                                                                                               |
| Masks had IoU 0 vs rembg: sharp 0.35 widens a resized 1-channel raw image to 3 channels                    | rembg parity check          | `.toColourspace("b-w")` + channel assertion                                                                                                                                                                                                                         |
| Overlapping settings saves shared one temp file (ENOENT), leaked it on failure, changed memory before disk | Test worker                 | Serialized saves, unique temp names, cleanup, commit-after-write                                                                                                                                                                                                    |
| Hand-edited settings could load an inconsistent shadow/opacity pair                                        | Test worker                 | `load()` applies the same rules as the controls                                                                                                                                                                                                                     |
| A dot-file dropped directly was accepted                                                                   | Test worker                 | Hidden names skipped at the top level too                                                                                                                                                                                                                           |
| Queue returned its internal row objects                                                                    | Test worker                 | Copies everywhere                                                                                                                                                                                                                                                   |
| Input size cap could overshoot for thin images                                                             | Test worker                 | `fitArea` fits both sides, orientation-aware                                                                                                                                                                                                                        |
| A late failure of a disposed model load cleared the newer load                                             | Test worker                 | Reset only its own attempt                                                                                                                                                                                                                                          |
| App would re-process its own results when a parent folder was dropped                                      | Lead, comparing CLI and app | Shared `inside_output` rule                                                                                                                                                                                                                                         |
| ag-psd 31.0.3 truncates the flattened image of 1–2 px wide canvases                                        | PSD worker                  | Refused with a clear error (`MIN_PSD_WIDTH = 3`)                                                                                                                                                                                                                    |
| Engine utility process died (exit code 5) on the 2nd IS-Net image of every run                             | First end-to-end run        | Isolated to ONNX Runtime's CPU arena inside an Electron utility process (bare ORT reproduces it; plain Node and `ELECTRON_RUN_AS_NODE` do not). `enableCpuMemArena: false`, `enableMemPattern: false`, fetch only output 0. Peak memory 1.7 GB → 0.6 GB, same speed |
| Hovered Start button was white text on white                                                               | End-to-end screenshot       | Primary hover rule now outranks the generic one; e2e asserts it                                                                                                                                                                                                     |

## 10. Known limits and differences by design

- **Shadows are local approximations**: remove.bg's are AI renders on its
  server. `auto` cannot detect cars, so it uses the generic
  contact style at 50 %. Check how they look before calling them done.
- **Cutout quality differs from remove.bg's** server model; IS-Net is good
  but untested side by side against remove.bg output. Hair and
  semi-transparent objects (glass, veils) will be weaker; there is no
  "semi transparency" layer.
- **No edge colour decontamination**: remove.bg "applies RGB color corrections
  on edges"; we use original colours, so a coloured halo can appear on dark or
  saturated backgrounds.
- `type` (person/product) is accepted but does not change the model in the
  app. `u2net_human_seg` exists for the CLI only.
- Not included: Design Templates, login/API key/credits, the version check,
  auto-update, "Preview" as a free tier (here "Preview Size" just limits output
  to 0.25 MP).
- CPU only (ONNX Runtime CPU provider). DirectML/CoreML are not enabled.
- One image at a time.
- PSD shadow is a raster layer, not a vector fill.
- Max input 200 MB per file (decode cap 50 MP after downscaling; decode refuses
  above 1 gigapixel).

## 11. Edge cases to check, highest risk first

Each item: what to do → what should happen. "PC" = the owner's Windows PC.

### 11.1 Install and first run (PC)

1. `cd "Oscar's Remove BG"; npm install; npm start` in PowerShell → installs
   without build tools (sharp, onnxruntime-node and electron ship
   prebuilt win32-x64 binaries) and the window opens. The folder name has an
   apostrophe and a space; watch for quoting problems in npm scripts.
2. Windows on ARM (Snapdragon) → onnxruntime-node and sharp have win32-arm64
   builds; Electron too. Unverified.
3. First Start with no model cached → status bar shows "Downloading model…"
   and progress; 178 MB lands in `%LOCALAPPDATA%\Oscar's Remove BG\models`
   with a `.verified` sidecar. Second launch does not re-download or re-hash.
4. First Start offline → one alert ("Could not download the
   background-removal model … press Start again"), rows back to ready, no
   `.partial-*` file left. Reconnect, Start → works.
5. Corporate proxy / antivirus intercepting GitHub downloads → hash mismatch
   alert, not a corrupt model in use.
6. Kill the app mid-download → next run cleans nothing up automatically
   (`.partial-*` files are not swept; known gap) but still downloads fine.
7. SmartScreen / antivirus warnings for an unsigned Electron app run from
   source.

### 11.2 Inputs

8. Drag a folder with subfolders, dot-files, `.DS_Store`, `Thumbs.db`, a
   `.txt`, a `.HEIC` and a `.gif` → images added with structure kept;
   one sentence listing the rejection reasons; dot-files silently ignored.
9. Drop the same files twice → "already in the list".
10. Drop a folder that contains the output folder (e.g. all of Pictures with
    the default output inside it) → files inside the output folder are
    rejected ("inside the output folder"). Check case differences
    (`C:\Users\X\pictures` vs `Pictures`) are still caught.
11. Unicode, emoji, apostrophes, very long names; paths longer than 260
    characters in deep folders (input and output) → processed or a clear
    per-row error, never a crash. Output names keep the input name.
12. `photo.JPG` and `photo.jpg` in the same folder on Windows → same output
    `photo.png` (case-insensitive file system); the second is skipped.
    `a.jpg` and `a.png` in one folder → same output; second skipped.
13. Files that disappear between adding and Start → per-row error, run
    continues.
14. Network drive / OneDrive "online-only" files (placeholder files that
    download on open) → slow but should work; check error text if offline.
15. Drop text, a URL or an image dragged from a browser (not a file) → nothing
    happens, no navigation, no crash.
16. 1,000+ images → **performance risk**: every row change sends the whole
    snapshot over IPC and the renderer re-renders; may need throttling or a
    row-diff push.

### 11.3 Image content

17. EXIF orientations 2–8 (phone photos) → output upright, same as the
    photo viewer shows.
18. CMYK JPEG, 16-bit PNG, grayscale PNG, palette PNG, PNG/WebP with
    transparency (flattened on white before segmentation), animated WebP
    (first frame), multi-page TIFF (first page), TIFF with alpha, Display-P3
    or Adobe RGB ICC profiles (converted to sRGB) → no crash; colours look
    right.
19. Images over 50 MP (e.g. 12000x8000) → downscaled to ≤ 50 MP before
    processing; output reflects that. Watch memory (~4 bytes/pixel several
    times over) and the utility process not being killed.
20. Tiny images (1x1, 2x2, 3x10) → either a result or "Could not identify
    foreground in image."; PSD of a 1–2 px wide result → clear error row.
21. No obvious subject (a sky, a white wall, a flat colour) → "Could not
    identify foreground in image." as a per-row error, run continues.
22. Hard cases for quality: hair, fur, glass, smoke, a white product on a
    white background, multiple people, a subject touching the frame edge, a
    car with reflections → compare with remove.bg's own output if available.

### 11.4 Outputs

23. Transparent PNG → pixels with alpha 0 have RGB 0 (no hidden background
    left in the file; check with an image editor's "remove alpha"). WebP is
    lossy: alpha-0 pixels next to the subject can keep small RGB values (≤ ~19).
24. Colored background → JPEG, colour exact, quality 0.92; check a
    semi-transparent edge blends smoothly.
25. DPI: a 300 DPI JPEG, PNG and TIFF input → output reports 300 DPI in
    Windows file properties / Photoshop; an input without DPI → no DPI
    written (JPEG viewers will show 72 or 96).
26. PSD: open in Photoshop, Photopea and GIMP → layer names, hidden original,
    editable mask (paint on it with a brush), shadow layer, DPI, transparent
    composite thumbnail.
27. Preview size → ≤ 250,000 pixels, aspect kept.
28. Existing output → row "Skipped: File already exists", file untouched,
    "Open result" opens the existing file.
29. Output folder read-only, on a full disk, or deleted mid-run → the
    matching alert once, the run stops, rows can be restarted.
30. Output folder on another drive or a network share → `"wx"` writes work.

### 11.5 Settings and UI

31. Every control persists across restarts (`%APPDATA%\Oscar's Remove BG\settings.json`).
    Corrupt that file by hand → app starts with defaults.
32. Choosing a shadow resets opacity to its default; Custom 0..100; Off
    disables opacity; "Mixed (Default)" only with Autodetect.
33. Photoshop file checkbox only in Transparent mode; status bar format text
    switches png/jpg/psd.
34. Controls are disabled while processing; Cancel → "Stopping..." → current
    image finishes → "Finished"; Start resumes the rest.
35. Fast/Best switch → the other model downloads on first use; only one stays
    in memory.
36. High-DPI scaling (125 %/150 %), dark mode, keyboard-only use (Tab, Enter,
    Space), screen reader labels.
37. Second launch while running → focuses the existing window
    (single-instance lock).
38. Open result / Show in folder / Open output folder with paths containing
    spaces and unicode.

### 11.6 Security and robustness

39. The page cannot read or write arbitrary files: try calling
    `window.removeBg` with crafted ids or values in DevTools → nothing outside
    the list/settings is opened; `settings:update` with junk is ignored.
40. A crafted image (decompression bomb, truncated file) → per-row error, no
    hang; engine process crash → alert, next Start works.
41. Model file tampered after download (edit a byte, keep size) → the sidecar
    no longer matches mtime, so it is re-hashed and re-downloaded.

### 11.7 macOS and Linux (lower priority)

42. macOS: menus (default Electron menu kept), Gatekeeper on an unsigned app,
    `~/Pictures` access prompt, Apple Silicon binaries.
43. Linux: `npm install` needs `ONNXRUNTIME_NODE_INSTALL=skip` only if
    nuget.org is blocked; otherwise it downloads CUDA providers (~hundreds of
    MB) that are not used.

## 12. Suggested next steps

1. Run sections 11.1–11.4 on the owner's PC (nothing has run on Windows yet
   except the collector). Item 1 first.
2. Confirm the IS-Net arena fix on Windows: process 10+ images in one run with
   the Best model and watch the "Oscar's Remove BG engine" process in Task
   Manager (expect well under 1 GB at 12 MP; a crash shows as the alert "The
   image engine stopped unexpectedly").
3. Compare a few cutouts with remove.bg's own output for the same photos.
4. Optional: edge colour decontamination; a person model when `type=person`;
   DirectML on Windows; electron-builder installer; IPC row diffs for large
   lists; sweeping stale `.partial-*` model files.
