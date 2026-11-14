const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const zlib = require('node:zlib');
const { Readable } = require('node:stream');

const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const ASSETS = { '/hero.webp': 'image/webp', '/tracks.webp': 'image/webp', '/tile-small.png': 'image/png', '/tile-big.png': 'image/png' };
const HOSTS = new Set(['soundcloud.com', 'www.soundcloud.com', 'm.soundcloud.com', 'on.soundcloud.com']);
const FFMPEG = process.env.FFMPEG_PATH || 'ffmpeg';
const DIR = path.join(os.tmpdir(), 'downcloud-jobs');
// ponytail: in-memory jobs are lost on restart (files in DIR are orphaned until the OS cleans tmp).
const jobs = new Map();
const playlists = new Map();

// ---- pure helpers ----
function isAllowedSoundCloudUrl(s) {
  try {
    const u = new URL(s);
    return (u.protocol === 'http:' || u.protocol === 'https:') && HOSTS.has(u.hostname);
  } catch { return false; }
}

// Returns {t, copy} or null. copy=true means the stream is already MP3 and is remuxed, not re-encoded.
function pickTranscoding(list) {
  const mp3 = (t) => /^audio\/mpeg\s*(;|$)/.test(t.format?.mime_type || '');
  const p = list.find((t) => t.format?.protocol === 'progressive' && mp3(t));
  if (p) return { t: p, copy: true };
  const h = list.find((t) => t.format?.protocol === 'hls' && mp3(t));
  if (h) return { t: h, copy: true };
  // audio/mpegurl (abr_sq) is an adaptive master playlist whose stream URL 404s; skip it.
  const o = list.find((t) => ['hls', 'progressive'].includes(t.format?.protocol) && !/mpegurl/.test(t.format?.mime_type || ''));
  return o ? { t: o, copy: false } : null;
}

// Store-only ZIP (zip32). Yields buffers: per entry header+name+data, then central directory, then EOCD.
// ponytail: zip32 only, so 4GB total / 65535 entries ceiling; switch to zip64 if playlists ever get that big.
function* zipChunks(entries) {
  const d = new Date();
  const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1);
  const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate();
  const central = [];
  let offset = 0;
  for (const { name, data } of entries) {
    const nm = Buffer.from(name);
    const crc = zlib.crc32(data);
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0); h.writeUInt16LE(20, 4); h.writeUInt16LE(0x0800, 6); h.writeUInt16LE(0, 8);
    h.writeUInt16LE(time, 10); h.writeUInt16LE(date, 12); h.writeUInt32LE(crc, 14);
    h.writeUInt32LE(data.length, 18); h.writeUInt32LE(data.length, 22); h.writeUInt16LE(nm.length, 26);
    central.push({ nm, crc, size: data.length, offset });
    offset += 30 + nm.length + data.length;
    yield h; yield nm; yield data;
  }
  let cdSize = 0;
  for (const e of central) {
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); c.writeUInt16LE(0x0800, 8); c.writeUInt16LE(0, 10);
    c.writeUInt16LE(time, 12); c.writeUInt16LE(date, 14); c.writeUInt32LE(e.crc, 16);
    c.writeUInt32LE(e.size, 20); c.writeUInt32LE(e.size, 24); c.writeUInt16LE(e.nm.length, 28);
    c.writeUInt32LE(e.offset, 42);
    cdSize += 46 + e.nm.length;
    yield c; yield e.nm;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(central.length, 8); end.writeUInt16LE(central.length, 10);
  end.writeUInt32LE(cdSize, 12); end.writeUInt32LE(offset, 16);
  yield end;
}
const zipEntries = (entries) => Buffer.concat([...zipChunks(entries)]);

function safeFilename(name) {
  const s = String(name ?? '').replace(/[\u0000-\u001f\u007f]/g, '').replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim().replace(/^\.+/, '').slice(0, 150);
  return s || 'track';
}

// Names inside one zip must differ (case-insensitively, like the Mac's disk): repeats get " (2)", " (3)".
function uniqueNames(names) {
  const used = new Set();
  return names.map((n) => {
    let s = n;
    for (let i = 2; used.has(s.toLowerCase()); i++) s = `${n} (${i})`;
    used.add(s.toLowerCase());
    return s;
  });
}

// ---- soundcloud ----
let clientId = null;
async function refreshClientId() {
  const html = await (await fetch('https://soundcloud.com/', { headers: { 'User-Agent': UA } })).text();
  const srcs = [...html.matchAll(/<script[^>]+crossorigin[^>]+src="(https:\/\/a-v2\.sndcdn\.com\/assets\/[^"]+\.js)"/g)].map((m) => m[1]);
  for (const src of srcs.reverse()) {
    const js = await (await fetch(src, { headers: { 'User-Agent': UA } })).text();
    const m = js.match(/client_id\s*[:=]\s*"?([a-zA-Z0-9]{32})/);
    if (m) return (clientId = m[1]);
  }
  throw new Error('Could not find a SoundCloud client_id.');
}

// GET json from api-v2 (adds client_id); refresh once on 401/403.
async function scJson(url, params = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const id = clientId || (await refreshClientId());
    const u = new URL(url);
    for (const [k, v] of Object.entries({ ...params, client_id: id })) u.searchParams.set(k, v);
    const r = await fetch(u, { headers: { 'User-Agent': UA } });
    if ((r.status === 401 || r.status === 403) && attempt === 0) { clientId = null; continue; }
    if (!r.ok) throw new Error(`SoundCloud returned HTTP ${r.status}.`);
    return r.json();
  }
}

async function finalUrl(url) {
  if (new URL(url).hostname !== 'on.soundcloud.com') return url;
  const r = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': UA } });
  r.body?.cancel();
  const f = new URL(r.url);
  if (!isAllowedSoundCloudUrl(r.url) || f.hostname === 'on.soundcloud.com') throw new Error('Short link did not lead to soundcloud.com.');
  return r.url;
}

const resolveUrl = async (url) => scJson('https://api-v2.soundcloud.com/resolve', { url: await finalUrl(url) });
const artistOf = (t) => t.publisher_metadata?.artist || t.user?.username || '';
const imageOf = (t) => (t.artwork_url || t.user?.avatar_url || '').replace('-large.', '-t500x500.');
function checkStreamable(t) {
  if (t.policy === 'BLOCK' || t.streamable === false) throw new Error('This track is not streamable.');
}

// Resolved playlists only carry a few full tracks; the rest are stubs ({id} only). Fetch them, keep order, skip missing.
async function playlistTracks(pl) {
  const items = pl.tracks || [];
  const got = new Map(items.filter((t) => t.title).map((t) => [t.id, t]));
  const full = got.size;
  const stubs = items.filter((t) => !t.title).map((t) => t.id);
  // Private (secret-link) sets return empty stubs unless the playlist id and token ride along.
  const priv = pl.secret_token ? { playlistId: pl.id, playlistSecretToken: pl.secret_token } : {};
  for (let i = 0; i < stubs.length; i += 50) {
    for (const t of await scJson('https://api-v2.soundcloud.com/tracks', { ids: stubs.slice(i, i + 50).join(','), ...priv })) got.set(t.id, t);
  }
  return { tracks: items.map((t) => got.get(t.id)).filter(Boolean), full, stubs: stubs.length };
}

// ---- jobs ----
// ponytail: global cap of 2 concurrent ffmpeg jobs; raise MAX_JOBS if the machine can take more.
const MAX_JOBS = 2;
let running = 0;
const waiting = [];
const acquire = () => new Promise((r) => { if (running < MAX_JOBS) { running++; r(); } else waiting.push(r); });
const release = () => { const n = waiting.shift(); if (n) n(); else running--; };

function update(job, p, text) { job.progress = p; job.text = text; }
const mapProgress = (frac) => Math.round(100 + frac * 850);

async function fetchCover(track, file) {
  const url = imageOf(track);
  if (!url) return false;
  try {
    const r = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(15000) });
    if (!r.ok) return false;
    fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
    return true;
  } catch { return false; }
}

function ffmpeg(job, args, durationMs) {
  return new Promise((resolve, reject) => {
    const f = spawn(FFMPEG, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let err = '';
    let buf = '';
    f.stderr.on('data', (c) => { err = (err + c).slice(-2048); });
    f.stdout.on('data', (c) => {
      const lines = (buf + c).split('\n');
      buf = lines.pop();
      for (const l of lines) {
        const m = l.match(/^out_time_us=(\d+)/);
        if (m && durationMs) update(job, mapProgress(Math.min(1, m[1] / 1000 / durationMs)), 'Converting');
      }
    });
    f.on('error', reject);
    f.on('close', (c) => (c === 0 ? resolve() : reject(new Error('ffmpeg failed: ' + err.trim()))));
  });
}

async function run(job, track, meta) {
  const cover = path.join(DIR, job.id + '.cover');
  await acquire();
  try {
    fs.mkdirSync(DIR, { recursive: true });
    checkStreamable(track);
    const out = path.join(DIR, job.id + '.mp3');
    job.file = out;
    const pick = pickTranscoding(track.media?.transcodings || []);
    if (!pick) throw new Error('This track has no usable audio stream.');
    update(job, 100, 'Converting');
    const { url: streamUrl } = await scJson(pick.t.url, { track_authorization: track.track_authorization });
    const hasCover = await fetchCover(track, cover);
    const year = (track.release_date || track.created_at || '').slice(0, 4);
    const tags = {
      title: track.title, artist: artistOf(track), album: meta.album,
      track: meta.album && `${meta.n}/${meta.total}`, date: /^\d{4}$/.test(year) && year,
      genre: track.genre, comment: track.permalink_url,
    };
    const args = ['-y', '-nostats', '-progress', 'pipe:1', '-i', streamUrl];
    if (hasCover) args.push('-i', cover);
    args.push('-map', '0:a:0');
    if (hasCover) args.push('-map', '1:v:0', '-c:v', 'copy', '-disposition:v:0', 'attached_pic', '-metadata:s:v', 'title=Album cover', '-metadata:s:v', 'comment=Cover (front)');
    args.push(...(pick.copy ? ['-c:a', 'copy'] : ['-c:a', 'libmp3lame', '-q:a', '2']), '-id3v2_version', '3', '-write_id3v1', '1');
    for (const [k, v] of Object.entries(tags)) if (v) args.push('-metadata', `${k}=${v}`);
    args.push(out);
    await ffmpeg(job, args, track.duration);
    Object.assign(job, { success: 1, progress: 1000, text: 'Finished', download_url: '/file/' + job.id });
  } catch (e) {
    Object.assign(job, { success: 0, progress: 1000, text: 'Error', message: e.message });
    if (job.file) fs.rm(job.file, { force: true }, () => {});
  } finally {
    release();
    fs.rm(cover, { force: true }, () => {});
  }
  setTimeout(() => { if (job.file) fs.rm(job.file, { force: true }, () => {}); jobs.delete(job.id); }, 60 * 60 * 1000).unref();
}

function startJob(track, meta = {}) {
  const id = crypto.randomBytes(12).toString('base64url');
  const title = track.title || 'track';
  const artist = artistOf(track);
  const job = { id, success: 0, progress: 0, text: 'Queued', download_url: null, name: artist ? `${artist} - ${title}` : title };
  if (track.policy === 'SNIP') job.message = 'preview only (30s)';
  jobs.set(id, job);
  run(job, track, meta);
  return job;
}

// ---- http ----
function send(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

async function handle(req, res) {
  const u = new URL(req.url, 'http://localhost');
  if (u.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(__dirname, 'index.html')));
  }
  if (ASSETS[u.pathname]) {
    res.writeHead(200, { 'Content-Type': ASSETS[u.pathname] });
    return res.end(fs.readFileSync(path.join(__dirname, u.pathname.slice(1))));
  }
  if (u.pathname === '/api/download') {
    const url = u.searchParams.get('url') || '';
    if (u.searchParams.get('format') !== 'mp3') return send(res, 400, { success: false, message: 'Only format=mp3 is supported.' });
    if (!isAllowedSoundCloudUrl(url)) return send(res, 400, { success: false, message: 'Please enter a soundcloud.com link.' });
    let item, pl;
    try {
      item = await resolveUrl(url);
      if (item.kind === 'track') checkStreamable(item);
      else if (item.kind === 'playlist') pl = await playlistTracks(item);
      else throw new Error(`That link is a ${item.kind}; only tracks and playlists are supported.`);
    } catch (e) { return send(res, 400, { success: false, message: e.message }); }
    const row = (t, job) => ({ title: t.title || 'track', artist: artistOf(t), duration: t.duration, progress_url: '/api/progress?id=' + job.id });
    if (!pl) return send(res, 200, { success: true, kind: 'track', tracks: [row(item, startJob(item))] });
    const id = crypto.randomBytes(12).toString('base64url');
    const title = item.title || 'playlist';
    const total = pl.tracks.length;
    const list = pl.tracks.map((t, i) => startJob(t, { album: title, n: i + 1, total }));
    playlists.set(id, { title, jobs: list.map((j) => j.id) });
    setTimeout(() => playlists.delete(id), 60 * 60 * 1000).unref();
    console.log(`playlist ${id}: ${total} tracks, ${pl.full} full from resolve, ${pl.stubs} stubs`);
    return send(res, 200, {
      success: true, kind: 'playlist', title, tracks: pl.tracks.map((t, i) => row(t, list[i])), zip_url: '/zip/' + id,
    });
  }
  if (u.pathname === '/api/progress') {
    const job = jobs.get(u.searchParams.get('id'));
    if (!job) return send(res, 404, { success: false, message: 'Unknown id.' });
    const { success, progress, text, download_url, message } = job;
    return send(res, 200, { success, progress, text, download_url, ...(message && { message }) });
  }
  if (u.pathname.startsWith('/file/')) {
    const job = jobs.get(u.pathname.slice(6));
    if (!job || job.text !== 'Finished') return send(res, 404, { success: false, message: 'Not found.' });
    res.writeHead(200, {
      'Content-Type': 'audio/mpeg',
      'Content-Length': fs.statSync(job.file).size,
      'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(safeFilename(job.name) + '.mp3')}`,
    });
    return fs.createReadStream(job.file).pipe(res);
  }
  if (u.pathname.startsWith('/zip/')) {
    const pl = playlists.get(u.pathname.slice(5));
    if (!pl) return send(res, 404, { success: false, message: 'Not found.' });
    const js = pl.jobs.map((id) => jobs.get(id));
    const done = js.filter((j) => j && j.progress >= 1000).length;
    if (done < js.length) return send(res, 409, { success: false, message: `Still converting (${done}/${js.length})` });
    const ok = js.filter((j) => j.text === 'Finished');
    const names = uniqueNames(ok.map((j) => safeFilename(j.name)));
    function* files() {
      for (let i = 0; i < ok.length; i++) yield { name: names[i] + '.mp3', data: fs.readFileSync(ok[i].file) };
    }
    res.writeHead(200, {
      'Content-Type': 'application/zip',
      'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(safeFilename(pl.title) + '.zip')}`,
    });
    return Readable.from(zipChunks(files())).on('error', () => res.destroy()).pipe(res);
  }
  send(res, 404, { success: false, message: 'Not found.' });
}

// Resolves to the bound port. Always listens on loopback only.
function start(port, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    if (spawnSync(FFMPEG, ['-version']).status !== 0) return reject(new Error('ffmpeg is required'));
    const server = http.createServer((req, res) => handle(req, res).catch((e) => { if (!res.headersSent) send(res, 500, { success: false, message: e.message }); else res.end(); }));
    server.once('error', reject);
    server.listen(port, host, () => resolve(server.address().port));
  });
}

if (require.main === module) {
  start(process.env.PORT || 8787).then((p) => console.log(`http://localhost:${p}`), (e) => { console.error(e.message + ' (brew install ffmpeg)'); process.exit(1); });
}

module.exports = { start, isAllowedSoundCloudUrl, pickTranscoding, safeFilename, uniqueNames, zipEntries };
