# FileChanger

FileChanger is a menu-bar file converter and file-tool app for macOS. It is an independent, clean-room replica of
[Tangerine](https://apps.apple.com/app/tangerine) 2.0.4: the same drag-to-convert wheels, tools and key-binds, written
from scratch in Swift on top of Apple's own frameworks. Its behavior was recovered with REA (this repository's
reverse-engineering tool) from a copy of Tangerine the owner bought; no Tangerine code, assets, sounds or keys are
included. See [Provenance](#provenance).

## Use it

FileChanger lives in the menu bar. Start dragging one or more files (from Finder, the Desktop, a Float shelf, or any
app that drags files), and while you hold the drag, **tap** a modifier key to open a wheel at the cursor. Holding the
key before you start the drag works too: the wheel opens as soon as the drag begins. Drop the files on a petal.

| Tap while dragging | Wheel | What a petal does |
| --- | --- | --- |
| **Shift** | Conversion | Converts every file to that format, saved next to the original with the new extension. |
| **Command** | Tools | Opens the tool's window (Trim, Crop, Compress, Redact, Merge PDFs, ...). Its Save button writes a new copy next to the original. |
| **Control** | Actions | Copy paths, Copy files, Move to a folder, Open Terminal in the folder, AirDrop, or put the files on a Float shelf. |

The modifiers can be changed in **Settings > General > Drag Modifiers**. Originals are never changed. Escape, or
dragging away, closes a wheel. Files opened on the app (`open -a FileChanger file.png`) get a Conversion wheel at the
pointer that you click instead of drop on.

FileChanger needs one permission: **Accessibility** (System Settings > Privacy & Security > Accessibility), because
macOS only lets an app see modifier-key taps made inside another app's drag when it has that permission. The menu shows
"Allow Wheel Shortcuts…" until it is granted. Moving files out of Desktop, Documents or Downloads may make macOS ask
once more for those folders.

### What it can do

- **Conversion wheel**: 47 formats in images, documents, spreadsheets, presentations, ebooks, audio, video, archives and
  subtitles, with the same source-to-target matrix as Tangerine. **Settings > Formats** holds each output format's
  defaults (quality, maximum video height, audio bit rate and bit depth, GIF frame rate and width, metadata, PDF and
  EPUB layout), and **Settings > Compatibility** shows the whole matrix.
- **Image tools**: Resize, Compress (level, percentage or target size), Crop (ratios, apply to all), Edit (19
  adjustment sliders), Annotate (arrows, shapes, highlighter, numbers, magnifier, text, pasted images), Collage,
  Add BG (frames with solid and gradient backgrounds), Redact (solid or blur, automatic face and text detection),
  Read QR Codes, and Metadata (view, edit, remove single fields, or Remove All with verification that pixels are
  unchanged and no private data is left).
- **Video tools**: Trim, Split (separate clips or one video), Join, Remove Audio, Change Speed (0.25x to 4x, pitch
  kept), Snapshots, Crop (with maximum height), Redact (rectangles over time ranges, solid or blur), Compress
  (balanced or strong, a percentage, or a target size).
- **Audio tools**: Trim (with automatic silent-end trimming), Convert Channels (mono or stereo, left/right volume),
  Normalize Volume (EBU R128 / BS.1770 loudness, loudness range, true-peak limit), Bleep, and Audio Visualizer (a
  waveform or still-image video).
- **PDF and archive tools**: Create PDF, Merge PDFs, Split PDF, Organize PDF (reorder, rotate, delete pages),
  Convert to PDF/A, Extract Archive.
- **Float**: a floating shelf that holds files for later: attach it to a screen edge, Quick Look with Space, drag files
  back out, sort by name.

## Install it

Build it on the Mac (Command Line Tools are enough; Xcode is not needed):

```bash
cd FileChanger
scripts/build.sh release
```

```bash
cp -R build/FileChanger.app /Applications/
```

```bash
open /Applications/FileChanger.app
```

Or make an installer disk image: `scripts/make-dmg.sh` builds, runs every test, and writes `build/FileChanger.dmg`.
Open it and drag FileChanger onto Applications, or double-click **Setup & Test** to install it and run the self-test
(the unit tests, the signature and a launch check). The window background is rendered once by
`scripts/make-dmg-background.swift` into `dmg/` (not committed).

The app is ad-hoc signed for personal use, like Oscar's Whisper. The first launch shows the Welcome window and a
practice wheel.

### Optional: more formats

Apple's frameworks cannot write MP3, Ogg, Opus, WMA, WebM, MKV, AVI, WMV or WebP. FileChanger never ships or downloads
encoders, but it uses them when you install them, and the matching petals then appear:

```bash
brew install ffmpeg webp
```

## How it mirrors Tangerine

| Feature | What REA found in Tangerine | FileChanger |
| --- | --- | --- |
| Wheels | A drag monitor; tapping a modifier mask during a file drag opens one of three glass "fans" (defaults Shift, Command, Control; masks in UserDefaults, with a one-time migration of the Tools wheel to Command). | Same three wheels, defaults, mask encoding and migration, drawn as its own glass petals with a synthesized hover tick. |
| Conversions | 47 `ConversionFormat`s and a fixed source-to-target matrix; bundled ffmpeg, cwebp, a Java runtime with Apache POI, ExifTool, and JavaScript for Pages/Office. | The same matrix, done with ImageIO, AVFoundation, PDFKit, Vision, NSAttributedString, WebKit and Quick Look, plus its own Markdown, EPUB, XLSX/ODS and zip code. ffmpeg/cwebp only if installed. |
| Tools | About 30 tools in a floating options window, each saving a new copy beside the original, with shared progress windows. | The same tools, labels, messages and key-binds, in a floating panel with the shared progress window. |
| Metadata | ExifTool scripts that list, edit and strip fields and verify the cleaned file. | ImageIO and PDFKit with the same fail-closed checks (pixel hash, no private tags left). |
| Float, Welcome, Settings | Float shelf, onboarding with a practice wheel, five-tab Settings. | Same, minus the sandbox folder-access step (FileChanger is not sandboxed). |
| Paywall | RevenueCat, usage counting, reviews, an ads SDK. | None. Everything is unlocked and nothing touches the network. |

The full checklist (318 items, each with its evidence) is in [docs/inventory](docs/inventory/README.md).

## Known differences and limits

See [HANDOFF.md](HANDOFF.md) for the item-by-item review results. In short:

- No Pages (`.pages`) input or output, no old Excel `.xls` input, no ASS/SSA/SBV subtitles.
- Without ffmpeg, lossy audio other than AAC is written as M4A (AAC), and the panels say so.
- Office documents to PDF are rendered through Quick Look or Core Text: tables and inline images in Word documents may
  be simplified; PDF to PowerPoint makes one picture per slide; PDF to SVG embeds page images.
- Convert to PDF/A writes PDF/A-2b identification and an sRGB output intent with Core Graphics and keeps fonts as the
  source embedded them; it has not been checked with a PDF/A validator.
- Resize, Crop, Edit, Add BG and Redact save new images without the original's EXIF, GPS and camera data (Compress and
  Metadata keep it).
- Audio with more than two channels works in Convert Channels, but Trim Audio and Normalize Volume refuse it.
- Video quality settings choose an export preset rather than an exact bit rate.
- Video chapters are not carried into edited copies.
- Real Finder drags onto the wheels (which need the Accessibility permission) have not been tested yet. The drag
  monitor, modifier-tap detection and petal hit-testing are covered by unit tests.

## Development

```bash
scripts/check.sh            # type-check the whole app (or: scripts/check.sh image|media|conversion|shell)
```

```bash
scripts/test.sh             # all unit tests (or one area: scripts/test.sh media)
```

```bash
scripts/build.sh            # debug build to build/FileChanger.app (BUILD_DIR=... for another folder)
```

SwiftPM is not used: on Command Line Tools 16.2 its `PackageDescription` library does not match the compiler, so
the scripts call `swiftc` directly and compile one module. XCTest needs Xcode, so tests use a small harness
(`Tests/Harness.swift`) and generate their images, audio, video and documents at run time; no binary fixtures are
committed. The app icon is drawn by `scripts/make-icon.swift` at build time.

| Folder | Contents |
| --- | --- |
| `Sources/Core` | File kinds, output naming and atomic writes, optional external tools, the tool and conversion contracts. |
| `Sources/UI` | The tool panel chrome and the shared progress window. |
| `Sources/App` | Entry point, hidden main menu, the tool catalog. |
| `Sources/Shell` | Menu bar, drag monitor, wheels, actions, Float, Welcome, Settings. |
| `Sources/Conversion` | Format model and matrix, conversion engines, PDF and archive tools, Formats/Compatibility settings. |
| `Sources/Image` | Image tools and metadata. |
| `Sources/Media` | Video and audio tools. |

Each area keeps non-UI code in `Engine/` (compiled into the tests) and SwiftUI/AppKit in `UI/`.

## Provenance

- An independent rewrite based on behavior recovered with REA from Tangerine 2.0.4, installed from the Mac App Store
  by the owner. How the evidence was gathered is in [docs/inventory/README.md](docs/inventory/README.md).
- No Tangerine source, scripts, JavaScript, Java, Perl, assets, icons, sounds or templates are included, and none of
  its bundled binaries are used. A RevenueCat key found in its `Info.plist` was deliberately left out. Short UI labels
  and messages were reused so the replica reads the same.
- The decompiled and extracted Tangerine material stayed in a temporary folder and was not committed.
- The app icon and the hover sound are original. FileChanger has no third-party dependencies.
