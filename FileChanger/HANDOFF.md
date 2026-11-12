# FileChanger: handoff

This file covers what was built, how it was checked, what broke and was fixed, and what still needs checking by hand.
Everything ran on the owner's Mac (Apple silicon, macOS 15, Command Line Tools 16.2, no Xcode). For install and
everyday use, see [README.md](README.md).

## 1. Status at a glance

| Area | State |
| --- | --- |
| Inventory | 318 rows across four files in [docs/inventory](docs/inventory/README.md), each with evidence and confidence. |
| Shell (menu bar, wheels, actions, Float, Welcome, Settings) | Built. Review round 2: about 88 PASS, 1 PARTIAL, 0 FAIL. 21 tests. |
| Conversion (47 formats, document/PDF/archive/subtitle tools) | Built. Review round 2: about 44 PASS, 9 PARTIAL, Pages and `.xls` left out on purpose. 29 tests. |
| Image tools and metadata | Built. Review round 2: about 42 PASS, 6 PARTIAL (optional extras), 0 FAIL. 37 tests. |
| Video and audio tools | Built. Review round 3: 52 PASS, 4 PARTIAL, 0 FAIL. 22 tests. |
| Whole app | `scripts/check.sh` type-checks all 71 files; `scripts/test.sh` runs all areas together: **113 passed, 0 failed**; `scripts/build.sh release` builds, and the app launches and stays up. |
| Real drags from Finder onto the wheels | **Not tested yet.** See section 6. |
| ffmpeg / cwebp formats | **Not tested with real output**: neither tool is installed on this Mac. See section 6. |

## 2. What was done, in order

1. **Recovered Tangerine's behavior with REA (static only).**
   - Target: the copy of Tangerine 2.0.4 the owner bought (`/Applications/Tangerine.app`, `com.th.Tangerine`, arm64).
   - REA `open_binary` and `inspect_macho` gave the Mach-O layout and linked frameworks. REA's decompiler providers
     (Ghidra, Hopper) were not installed, so no pseudocode was used.
   - `strings` of the binary gave UI text and Swift type names (cited in the inventory as `S:<line>`).
   - Swift stores strings of 15 bytes or fewer inside instructions, not as text, so `strings` misses tool labels,
     format names and modifier defaults. A small decoder was written that reads the `objdump` disassembly and tracks
     `mov`/`movk` register constants to rebuild those literals (cited as `L:<address>`). This is where the 47-format
     list, the wheel labels and the Shift/Command/Control defaults came from.
   - Bundle resources, `Info.plist`, entitlements and Tangerine's saved preferences were read for behavior only.
   - Tangerine was not run under observation: its menu-bar-only process is not visible to computer use on this Mac.
   - All extracted material stayed in a temporary folder and was not committed.
2. **Wrote the inventory.** Four inventory agents, one per area (shell, conversion, image, media), each read the
   shared evidence and wrote a checklist table: ID, behavior, labels/options/defaults, evidence, confidence
   (`observed`, `inferred`, `unknown`) and the native macOS route to use. Result: 318 rows (shell 96, conversion 124,
   image 45, media 53).
3. **Wrote the contracts** so four builders could work at once without touching each other's files:
   `Sources/Core` (file kinds, tool spec, output naming and atomic writes, optional external tools), `Sources/UI` (tool
   panel and shared progress window), the app entry and tool catalog in `Sources/App`, the test harness, and the
   `check.sh` / `test.sh` / `build.sh` scripts. Each script takes an area so one builder's half-finished work cannot
   break another's check.
4. **Built the four areas in parallel.** One builder agent per area (shell, conversion, image, media), each owning only
   its `Sources/<Area>` folder and `Tests/<Area>Tests.swift`, under one shared brief: match the inventory's labels,
   options, ranges, messages and key-binds exactly; pick sensible defaults where a row is `unknown` and report them;
   clean room (no Tangerine code, assets or binaries, no network).
5. **Reviewed each area in rounds.** A fresh reviewer agent per area judged every inventory row PASS / PARTIAL / FAIL
   from the code, the tests and its own harnesses: scratch programs that ran the engines on generated files, and an
   in-process app that opened each tool panel and rendered it to PNG. The builder fixed what the review found, and a
   new review checked the fixes. Shell, image and conversion passed in round 2; media needed round 3 (section 4).
6. **Integrated.** Whole-module type-check, all test suites joined into one runner, release build, launch check. No
   cross-area compile clashes turned up.

**Models.** The orchestrating session was Claude Opus 5.5. Inventory, builder and reviewer agents used the `sonnet`
alias, which ran Sonnet 5.5; Sonnet 4.6 specifically was not selectable.

## 3. Review results by area

Counts are rows judged by the reviewer. Rows owned by another area (for example the shell's key-bind rows for the
media editors) were judged by that area's reviewer.

| Area | Round 1 | Round 2 | Round 3 | Tests |
| --- | --- | --- | --- | --- |
| Shell | ~80 PASS, 9 PARTIAL, 0 FAIL | ~88 PASS, 1 PARTIAL (SHL-06), 0 FAIL | not needed | 20 → 21 |
| Image | 33 PASS, 15 PARTIAL, 0 FAIL | ~42 PASS, ~6 PARTIAL, 0 FAIL | not needed | 33 → 37 |
| Conversion | 38 PASS, 14 PARTIAL, 2 FAIL (Pages, `.xls`) | ~44 PASS, 9 PARTIAL, Pages/`.xls` hidden by design | not needed | 28 → 29 |
| Media | 44 PASS, 12 PARTIAL, 0 FAIL | 51 PASS, 5 PARTIAL, 0 FAIL, 1 must-fix | 52 PASS, 4 PARTIAL, 0 FAIL | 19 → 22 |

Core contract tests add 4, for 113 in all.

## 4. Bugs found by review (all fixed)

**Shell**
- A wheel could open from a stray modifier tap after a drag ended, if the global `leftMouseUp` was missed. The tap
  detector now also checks that the mouse button is down.
- A drop on the wheel's hub or a gap left the wheel open. It now closes when the drag ends, and its hit area is a
  circle, not the panel's square.
- Petal labels were title-cased with `.capitalized`, giving "Merge Pdfs" and "Read Qr Codes". Acronyms are now kept
  (unit test added).
- The progress window said "Done" and played the success sound after Stop with nothing finished. It now shows
  "Stopped", and parallel jobs' windows cascade.
- Float: borderless panels cannot be resized from the edge (a corner grip was added), and drops from one Float shelf
  to another were refused.
- Closing Welcome with the red button did not mark it complete, so it came back on every launch.

**Image**
- Compress threw for animated images, WebP and AVIF in every mode, then told the user to pick a mode that also threw.
- Crop kept every selected photo's full-resolution image in memory (a 50-photo batch could use gigabytes).
- Annotate: starting a drag inside an existing shape always moved it, so no new shape could start there.
- Metadata: Remove All dropped PNG gamma and colour chunks; saving a C2PA row was silently ignored; Save stayed
  disabled after edits to a file other than the current one.
- Redact hid itself for multi-file selections instead of saying "Redact one still photo at a time."

**Conversion**
- A Quick Look failure on a presentation was reported as "larger than 128 MB".
- A format whose only problem was a missing ffmpeg/cwebp said "Input-only format." instead of "Unavailable for
  conversion." with the install hint.
- `.xls` and Pages were offered in the matrix but had no reader, so they failed only at run time. They are now hidden.
- Markdown to Word flattened headings and tables. It now writes Heading 1-3 styles and real tables.
- PDF/A claimed more than it did, and contained dead code. The caption now says exactly what is written.
- Long conversions could not be cancelled. Text, OCR and zip work moved off the main thread and checks for
  cancellation.

**Media**
- Joining clips that all lacked audio failed.
- AAC output failed with a raw Core Audio error (560226676) for 8 kHz mono and 16 kHz stereo sources: the bit rate is
  now chosen from the sample rate and channel count.
- Normalize Volume with a loudness range target landed about 1 LU below the target whenever gain riding engaged. The
  static gain is now re-aimed after the ride curve. On a dynamic test signal (source −17.99 LUFS, LRA 16), targets of
  −16 at ranges 11 / 5 / 3 now land at −16.00 LUFS with LRA 11.1 / 5.8 / 4.4.
- Split Video's Save button was clipped off the 720 × 560 panel, and its Export label wrapped.
- Redact Video (found in round 3): with even one layer, the Save/Cancel footer was pushed off the panel and "Start
  seconds" wrapped to three lines. The two lists are now sized to their content with a cap (two bars and one and a half
  rows show, more scroll), and field labels no longer wrap. Checked by rendering the panel with six layers.
- Bleep's preview rendered the whole file to a temporary file (about 600 MB for an hour). It now renders around the
  playhead.
- MP3 and other lossy sources come out as `.m4a` (AAC); the panels now say so.

## 5. Tests

```bash
scripts/test.sh
```

113 tests: core 4, conversion 29, image 37, media 22, shell 21. They run the real engines on images, audio, video and
documents generated at test time. No binary fixtures are committed. XCTest needs Xcode, so `Tests/Harness.swift` is a
small runner; `scripts/test.sh <area>` builds one area alone.

## 6. Not tested here, and why

- **Real Finder drags onto the wheels.** Tapping Shift, Command or Control during a Finder drag needs the
  Accessibility permission for FileChanger and full-screen control of the Mac to drive. The drag monitor, tap
  detection, wheel layout and hit-testing have unit tests; the live path has not been run.
- **ffmpeg and cwebp formats** (MP3, Ogg, Opus, WMA, WebM, MKV, AVI, WMV, WebP, AVIF). Neither tool is installed on
  this Mac, so only the "unavailable" behavior and the argument builders were tested.
- **Text-only PowerPoint decks through Quick Look.** Not confirmed with a real `.pptx`.
- **Clicking through the panels.** Synthetic mouse and accessibility events do not reach SwiftUI controls in an
  unattached panel, so panels were checked by rendering them to PNG and by reading the code. Annotate paste/undo and the
  media editors' Space and arrow keys are checked in code only.
- **PDF/A output** has not been run through a PDF/A validator.

## 7. Known differences and open items

By design:
- No Pages (`.pages`) input or output, no `.xls` input, no ASS/SSA/SBV subtitles.
- Video chapters are not carried into edited copies (AVFoundation's composition export drops them; other metadata is
  copied).
- Video quality settings choose an export preset rather than an exact bit rate.
- No paywall, usage counting, review prompts or network access.

Remaining PARTIAL rows (none blocking):
- SHL-06: About has no Support link, because FileChanger has no support address.
- Media: MED-06 audio-only tools reject video files instead of using their audio; MED-10 the redact fallback text is
  unused; VID-81 a trash button per layer rather than a "Delete Layer" menu; VID-90 chapters (above).
- Image: no scrub-drag on number fields (IMG-16), no arrow-key nudge in Annotate (SHL-92), text boxes are edited in the
  side inspector rather than in place (IMG-25), metadata limits (META-02), no audio/video metadata (META-07).
- Conversion: OCR does not detect headings; HTML and Word export still run on the main thread (about 1 s for a
  typical Markdown file).
- Audio with more than two channels is refused by Trim Audio and Normalize Volume ("This audio can't be processed.").
- Resize, Crop, Edit, Add BG and Redact write new images without the original's EXIF/GPS data. Redact should; the
  others may want to keep it (orientation reset to upright).

## 8. Defaults chosen where the inventory said `unknown`

| Row | Chosen |
| --- | --- |
| SHL-98 Fan dismissal | Closes on drop, when the drag ends anywhere else, 0.3 s after the drag leaves it, on Escape, and on a second tap of the same modifier. |
| SHL-106 Window sizes | Tool panels 720 × 560 (minimum 520 × 380), Settings 760 × 640. |
| AUD-42 Bleep output | Same format as the source (lossy sources as AAC `.m4a`); the bleep is a 1 kHz tone at 0.18 amplitude over the range, all channels. |
| CNV-09 Literal "3mf" | Not implemented (it is not a conversion format). |

Rows marked `inferred` were built as inferred and judged PASS by review when the result was sensible.

## 9. Suggested next steps

1. Run the real-drag smoke test: grant Accessibility, drag a file from Finder, and tap Shift, Command and Control.
2. `brew install ffmpeg webp` and convert one file into each ffmpeg/cwebp format.
3. Decide whether the image tools should keep EXIF (section 7).
4. Validate a PDF/A output with veraPDF.

## 10. Provenance

- FileChanger is an independent rewrite from behavior recovered with REA from Tangerine 2.0.4, installed from the Mac
  App Store by the owner.
- No Tangerine source, scripts, JavaScript, Java, Perl, assets, icons, sounds or templates are included, and none of
  its bundled binaries (ffmpeg, cwebp, a Java runtime, ExifTool) are used. A RevenueCat key found in its `Info.plist`
  was deliberately left out. Short UI labels and messages were reused so the replica reads the same.
- The only Tangerine-derived material committed is the inventory in `docs/inventory`, which describes behavior and
  cites evidence locations.
- The app icon (drawn by `scripts/make-icon.swift` at build time) and the hover tick (synthesized at run time) are
  original. FileChanger has no third-party dependencies.
