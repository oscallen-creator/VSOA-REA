# DownCloud

Paste a SoundCloud track or playlist link and get MP3s with cover art and tags. Playlists come as a zip.

## Download

- Mac (Apple Silicon): https://github.com/oscallen-creator/VSOA-REA/releases/download/downcloud-v1.1.0/DownCloud-Mac.dmg
- Windows: https://github.com/oscallen-creator/VSOA-REA/releases/download/downcloud-v1.1.0/DownCloud-Windows.exe
- All versions: https://github.com/oscallen-creator/VSOA-REA/releases?q=downcloud

## First launch

DownCloud is unsigned, so your computer will warn you the first time.

- **Mac:** open the DMG, drag DownCloud to Applications, then open it once. If macOS blocks it, go to System Settings → Privacy & Security → "Open Anyway" (or right-click the app → Open).
- **Windows:** SmartScreen appears → click "More info" → "Run anyway".
- Converted files save straight to your Downloads folder.

## Use from source

- `npm install`, then `npm start` opens the desktop window.
- `node server.js`, then open http://localhost:8787 for browser mode (needs ffmpeg on PATH).
- `npm test` runs the tests.
- `npm run dist:mac` builds the DMG locally.

## Releasing a new version

1. Bump `version` in `DownCloud/package.json`, then commit.
2. Tag and push: `git tag downcloud-vX.Y.Z && git push origin downcloud-vX.Y.Z`
3. GitHub Actions (`.github/workflows/downcloud-release.yml`) builds both installers and publishes a release. It is deliberately not marked "latest", so REA's own installer is unaffected.
4. Update the version in the Download links above.

## How it works

- A local Node server resolves SoundCloud's public api-v2.
- ffmpeg converts each stream to MP3 with an embedded cover and ID3 tags.
- Playlists are converted two at a time, then zipped.
- The job and progress-polling design was reverse-engineered from downcloud.cc with VSOA-REA. See [RE-FINDINGS.md](RE-FINDINGS.md).

## Notes

- Intel Macs aren't covered by this build.
- The bundled ffmpeg (ffmpeg-static) is GPL-licensed.
- Only download tracks you have the rights to. Respect artists and SoundCloud's terms.
