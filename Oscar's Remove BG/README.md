# Oscar's Remove BG

Removes image backgrounds on your own PC: transparent cutouts, a solid
background color, local shadows, a layered Photoshop file, and whole folders
at once. There's no account, no credits, and nothing is uploaded. After a
one-time model download it works offline.

It is a remake of the functions of **remove.bg for Windows 3.0.0**. The
design follows what [REA](../README.md) recovered from that app's Electron
bundle (see [How it mirrors remove.bg](#how-it-mirrors-removebg)). The code is
an independent rewrite. No remove.bg code, assets, keys or servers are used.
The background removal itself runs open-source models
([IS-Net](https://github.com/xuebinqin/DIS) and
[U²-Net](https://github.com/xuebinqin/U-2-Net), Apache-2.0) with
[ONNX Runtime](https://onnxruntime.ai).

## Run it (Windows)

You need Node.js 22 or newer (24 recommended) and Git. In PowerShell:

```powershell
cd "Oscar's Remove BG"
npm install
npm start
```

The first time you press **Start**, the app downloads the background-removal
model (179 MB) to `%LOCALAPPDATA%\Oscar's Remove BG\models` and checks its
SHA-256 fingerprint. After that it never needs the internet. The **Fast**
quality setting uses a 4.6 MB model instead.

## Use it

| Do this                                                | What happens                                                                             |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Drag images or folders into the window, or click **+** | They're added to the list. Folders are searched, including subfolders.                   |
| **Transparent** / **Colored**                          | Transparent PNG, or a JPEG on the color you pick (10 quick colors)                       |
| **Photoshop file** (transparent only)                  | A layered PSD with the cutout as an editable layer mask                                  |
| **Shadow** and **Opacity**                             | Off, Autodetect, Car, 3D or Drop Shadow; opacity resets to that shadow's default         |
| **Output size**                                        | Automatic or Full Size keeps the resolution (up to 50 MP); Preview Size makes it 0.25 MP |
| **Quality**                                            | Best (IS-Net) or Fast (small U²-Net)                                                     |
| **Output folder** / **Change**                         | Default `Pictures\Oscar's Remove BG`; click the path to open it                          |
| **Start** / **Cancel** / **Clear list**                | Cancel finishes the current image and stops; Start continues with the rest               |

Results keep the input's name and subfolders, for example
`Trip\beach.jpeg` becomes `Pictures\Oscar's Remove BG\Trip\beach.png`.
Existing files are never overwritten. Those images are marked
"Skipped: File already exists". The input's DPI is kept.

Accepted inputs are JPG, PNG, TIFF and WebP, up to 200 MB each. Files whose
names start with "." are ignored. So are files already inside the output
folder.

## Command line

The same engine works without the window, for scripts and large batches:

```powershell
npm run cli -- --help
npm run cli -- "C:\Photos\Trip" -o "C:\Photos\Cutouts"
npm run cli -- shoes.jpg --bg-color "#FFFFFF" --format jpg --crop --crop-margin 5%
npm run cli -- car.jpg --shadow car --format psd
```

The CLI also has the remove.bg API's other options: background image, crop
and margin, scale and position, region of interest, alpha-only matte, WebP and
zip (color.jpg + alpha.png) output, and `--json` output.

## How it mirrors remove.bg

| Feature    | What REA found in remove.bg 3.0.0                                                                                                       | Oscar's Remove BG                                                                             |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Cutout     | Every image is re-encoded as JPEG (quality 0.92, max 50 MP) and uploaded to remove.bg's server, which returns `color.jpg` + `alpha.png` | A local model makes the mask on your PC (IS-Net; masks match rembg's within 1/255 on average) |
| Output     | PNG (transparent) or JPEG 0.92 (colored), never overwrites; name = input path with a new extension                                      | Same rules; transparent pixels carry no hidden background                                     |
| Photoshop  | Layers: hidden original, shadows, cutout with an editable layer mask; DPI kept                                                          | Same layer structure                                                                          |
| Shadows    | Off / Autodetect / Car / 3D / Drop, rendered by the server's AI; defaults car 90 %, drop and 3D 50 %                                    | Local shadows from the subject's outline, same choices and defaults                           |
| Settings   | Output folder, PSD, shadow, opacity, background mode and color, size; 10-color palette                                                  | Same settings and defaults, plus Quality                                                      |
| Inputs     | Drag and drop with recursive folders, dot-files skipped, folder structure kept; JPG/PNG/TIFF/WEBP; duplicates rejected with one summary | Same                                                                                          |
| Queue      | 5 uploads at a time; Cancel lets in-flight work finish; per-row states                                                                  | One image at a time (the model already uses every core); same states and Cancel               |
| Status bar | "N files, Transparent bg, Output format: png", "Processing i of N file(s) (P %)", "Finished …"                                          | Same texts                                                                                    |

Not copied: login, API key, credits, Design Templates (they download and run
code from remove.bg's servers), the version check and auto-update. Also not
copied are the bugs REA found:

- a rate-limit retry that loops instantly
- a queue that stalls after an error
- DPI lost for PNG and WebP inputs
- the window being able to read and write any file

## Known differences and limits

- Shadows are approximations of remove.bg's AI shadows. Autodetect can't tell
  a car from anything else, so it uses a generic ground shadow at 50 %.
- Cutout quality comes from an open-source model, not remove.bg's.
  - Fine hair, glass and smoke are harder.
  - There is no edge color correction, so a faint fringe can show on strong
    backgrounds.
- It runs on the CPU only. On a 4-core machine one 12 MP photo takes about 2–4
  seconds with Best and well under a second with Fast.
- It has not been run on a real Windows or Mac computer yet. See
  [HANDOFF.md](HANDOFF.md) for the checklist.

## Development

```powershell
npm test   # 555 unit tests; 562 with OSCARS_REMOVE_BG_MODELS set to a folder holding u2netp.onnx
```

On Linux, `scripts/e2e-linux/run.mjs` runs the real app under Xvfb with
Playwright (9 scenarios). On Linux x64, run `npm install` with
`ONNXRUNTIME_NODE_INSTALL=skip` if nuget.org is blocked.

[HANDOFF.md](HANDOFF.md) has the architecture, file map, contracts, every test
and fix, and the full list of edge cases still to check.
