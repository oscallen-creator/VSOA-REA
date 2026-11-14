# DownCloud: notes for Claude

SoundCloud track/playlist link → MP3s with embedded cover + ID3 tags (title, artist, album, track n/total, year, genre). Electron window around a loopback-only Node server (`server.js`, stdlib only); ffmpeg comes from ffmpeg-static. Current release: **1.1.0**.

## Where things live

- **Source of truth:** github.com/oscallen-creator/VSOA-REA, folder `DownCloud/` on `main`. VSOA-REA is the rea-agents repo; DownCloud is a guest in it.
- **This folder (`~/DownCloud`)** is a non-git working copy kept identical to that folder. It holds node_modules and dist. Sync it after every push.
- **Installers** are GitHub Release assets: they're over 100 MB, so they can't be committed. Pushing tag `downcloud-vX.Y.Z` runs `.github/workflows/downcloud-release.yml`, which builds `DownCloud-Mac.dmg` (Apple Silicon, ad-hoc signed) and `DownCloud-Windows.exe` (NSIS) and publishes the release with `--latest=false`. The build takes about 3 minutes.

## Shipping a change (Oscar's workflow)

1. Clone fresh with a sparse checkout of `DownCloud` and `.github`, then symlink `node_modules` from `~/DownCloud`.
2. Test from source before pushing:
   - Run `npm test`.
   - Run `FFMPEG_PATH=node_modules/ffmpeg-static/ffmpeg PORT=8790 node server.js`, then check the page in the browser pane at about 453×868.
   - Check the real Electron window.
3. Bump `version` in package.json and the two README download links.
4. Commit as `chore(downcloud): …`. `chore` keeps release-please and the rea-agents changelog untouched, and the repo only allows conventional types.
5. Push `main`, then tag and push the tag.
6. Copy the changed files back into `~/DownCloud`.
7. Never touch his installed app. He reinstalls from the new DMG: drag to Applications → Replace → System Settings → Privacy & Security → "Open Anyway".
8. Group several changes into one release. Each release costs him a reinstall and a Gatekeeper prompt.

## UI (since 1.1.0)

- **Coordinates:** every position in `index.html` is a pixel coordinate in the 906 px-wide mockup, scaled by `--u` (container width / 906, via `cqw`). To move something, re-measure it on the mockup.
- **`hero.webp`:** the first screen (trumpet player). It holds the link field, the Convert button, the "Downloadable Tracks" heading and the first 4 tracks, plus a "⤓ ZIP" button and a status line that weren't in the mockup.
- **`tracks.webp`:** bird pages for tracks 5 and up, 11 rows per page. Rows 10–11 step right (`margin-left` 35/70 u) around the wing tip, and their row rules start later.
- **How the art was made:** both files are Oscar's mockups with the placeholder rows erased. The fill is smooth paper colour from the surrounding paper plus grain quilted from clean paper patches. For new art, measure the element boxes, erase placeholders the same way, then update the coordinates.
- **Row icons:** `tile-small.png` and `tile-big.png` are the cloud icons cropped from the mockups, with alpha. Rows show these, not track covers; covers are still embedded in the MP3s.
- **Window:** content height is 90% of the work area, with the aspect ratio locked to 906/1735 so the first screen fills it exactly.
- **Zip entries:** named `Artist - Title.mp3` with **no number prefix**, which Oscar explicitly asked for. Repeated names get " (2)". Track order lives in the ID3 tags.

## Security context

- **Audit (2026-11-13):** the Mac app was checked and is clean. Its code matches source, and the bundled Electron and ffmpeg match independently downloaded official copies.
- **Gatekeeper's "can't verify" warning** only means the app isn't notarized. Removing it needs a paid Apple Developer account ($99/yr).
- **Reverse-engineered sites:** `RE-FINDINGS.md` covers downcloud.cc and smdownloader. Only their architecture was copied. Never reuse their API keys or the p.savenow.to service.

## Known gaps

- The Windows .exe has never been run on Windows.
- Private-set (secret-token) links are untested.
- There's no Intel Mac build.
- The installers are unsigned.
- A second launch doesn't focus the existing window.
- Windows reserved names (CON etc.) aren't sanitized.
- Jobs are kept in memory and lost on restart.

## Don'ts

- Don't open VSOA-REA's `FileChanger` or `Oscar's Whisper` folders.
- Don't fix REA's failing `release.yml` / release-please or its stray `release-please--branches--main--components--rea-agents` branch; Oscar said leave it.
- Don't commit installers.

## Working with Oscar

- He's non-technical about packaging. Explain plainly and give one recommendation rather than a survey.
- He likes subagent model routing: Sonnet for builds, Haiku for mechanical work, the main model for review and integration.
- Keep code minimal.
