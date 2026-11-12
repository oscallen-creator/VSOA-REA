# Tangerine 2.0.4 feature inventory

The checklist FileChanger is built and reviewed against. Every row has a stable ID, the behavior, its evidence and
confidence (`observed`, `inferred`, `unknown`), and the native macOS route FileChanger uses.

| File | Area | Rows |
| --- | --- | --- |
| [shell.md](shell.md) | Menu bar, the three drag wheels, actions, Float shelf, Welcome, Settings, key-binds (`SHL`) | 96 |
| [conversion.md](conversion.md) | Format matrix and conversions (`CNV`), document and PDF tools (`DOC`), archives (`ARC`), subtitles (`SUB`) | 124 |
| [image.md](image.md) | Image tools (`IMG`) and metadata/privacy (`META`) | 45 |
| [media.md](media.md) | Video (`VID`), audio (`AUD`) and shared media tools (`MED`) | 53 |

## How it was recovered

Static analysis of the copy installed from the Mac App Store (`/Applications/Tangerine.app`, `com.th.Tangerine` 2.0.4,
arm64, binary SHA-256 `e94b293414beb3fd0ee155f5a5fe529c60d51e08f01447bd9a4d2915f112072d`):

- REA `open_binary` and `inspect_macho` (Evidence `ev_7eb268497683bf69bf780c169efe5036e33d7a664c1db548426cc52e68042807`)
  for the Mach-O layout and linked frameworks. REA's decompiler providers (Ghidra, Hopper) were not installed, so no
  pseudocode was used.
- `strings` of the binary for UI text and Swift type names (cited as `S:<line>`).
- Swift small-string literals (15 bytes or fewer, which Swift stores inside instructions rather than as text) recovered
  from the `objdump` disassembly by tracking `mov`/`movk` register constants (cited as `L:<address>`). This is how the
  format list, tool labels and modifier defaults were found.
- Bundle resources, `Info.plist`, entitlements and the app's saved preferences, read for behavior only.

Tangerine was not run under observation: its menu-bar-only process is not visible to computer use on this Mac. Rows
marked `unknown` (mostly numeric defaults, preset lists and exact layouts) were filled with reasonable defaults by the
builders and listed in their reports.

No Tangerine code, scripts, assets, sounds or keys were copied into FileChanger.
