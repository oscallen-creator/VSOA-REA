# downcloud.cc — how it works (REA findings)

Tooling: VSOA-REA (`rea-agents` 6.7.0) MCP — `capture_browser_scenario` (launched headless Chrome),
`export_web_scripts`. Evidence: page-load scenario `ev_10ebbf31…`, script export `ev_3fa0f832…`.

## Observed (from captured traffic + exported scripts)

downcloud.cc is a thin front end. It does **no** conversion itself. All work happens on a
third-party commercial API, `p.savenow.to` (it brands itself video-download-api.com and asks apps
to contact them before using it). downcloud ships that API's key in `js/shared/savenow-api.js`.

Flow for one track (captured for `https://soundcloud.com/forss/flickermood`, format `mp3`):

1. `GET  p.savenow.to/api/pow/challenge` → `{salt, difficulty:3, expires_at, signature}`
2. Browser brute-forces `sha256(salt + ":" + nonce)` until it starts with `difficulty` zeros (1 s budget)
3. `POST p.savenow.to/api/pow/verify` `{salt, difficulty, expires_at, signature, nonce}` → `{success, token, expires_at}`
   (token is cached in `sessionStorage.savenow_pow_token` and sent as `Authorization: Bearer`)
4. `GET  p.savenow.to/api/v2/download?format=mp3&url=<sc url>&apikey=<key>` →
   `{success:true, id, title, info:{image,title}, progress_url}`
5. Poll `progress_url` every **1500 ms** (max 120 attempts) →
   `{success:0, progress:10, text:"Initialising"}` … `{progress:650, text:"Converting"}` …
   `{success:1, progress:1000, text:"Finished", download_url, alternative_download_urls:[…]}`
6. The download button becomes a link to `download_url` (a savenow file host).

Formats offered for audio: mp3, m4a, webm, aac, flac, opus, ogg, wav. Progress uses a 0–1000 scale.
Failure = `success:false`, `progress>=1000` with no URL, or text matching error/failed/private/removed.

Everything else on the page is ads (apitiny, Turnstile bot check for the ad network), GA, and Cloudflare RUM.

## Design choice for our build (inference, not observed)

We copy the **architecture**: start a job, poll a progress URL, then download a file. We do **not** reuse
downcloud's API key or solve savenow's proof-of-work. That would mean using a paid third-party service
without permission. Our server does the conversion itself, using SoundCloud's public `api-v2` (the same
approach yt-dlp takes).

# smdownloader.com playlist downloader (REA findings)

Evidence: page-load scenario `ev_8802e901…`, script export `ev_50c95642…`. Bounded: 6 of the 24 first-party
scripts exceeded the capture budget and were not inspected.

- It's a Next.js app. Extraction is `POST /api/extract {url}`, behind a session token from `GET /api/session`.
  That session is gated by Cloudflare Turnstile (`x-cf-turnstile-response` header). The conversion backend is
  server-side and isn't visible from the client.
- SoundCloud URL parsing: `/^\/([^/]+)\/sets\/([^/?#]+)(?:\/(s-[A-Za-z0-9_-]+))?\/?$/`, with a `?secret_token=s-…`
  fallback. It also accepts `/likes` and `/reposts`. Hosts m.soundcloud.com and soundcloud.com are normalized.
- Playlist UX: "N tracks ready — preview any track, then Download the current one or Download all files",
  capped at a fixed number of tracks per extract. For SoundCloud playlists it saves one file at a time; its own
  copy says "ZIP is not available" (the server returns 501).

What we took from it: support for secret-token sets, and per-track rows with a "download all" action. One
deliberate difference: we offer a ZIP for the whole set, because our server is local and has no per-request quota.
