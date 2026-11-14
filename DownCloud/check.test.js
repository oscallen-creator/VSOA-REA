const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { isAllowedSoundCloudUrl, pickTranscoding, safeFilename, zipEntries } = require('./server.js');

test('allowed hosts', () => {
  for (const u of ['https://soundcloud.com/a/b', 'http://www.soundcloud.com/a', 'https://m.soundcloud.com/a', 'https://on.soundcloud.com/abc'])
    assert.ok(isAllowedSoundCloudUrl(u), u);
});

test('rejected hosts', () => {
  for (const u of ['https://soundcloud.com.evil.com/a', 'https://evilsoundcloud.com/a', 'http://localhost', 'http://127.0.0.1:8787', 'file:///etc/passwd', 'ftp://soundcloud.com/a', 'not a url', '', 'https://soundcloud.com@evil.com/'])
    assert.ok(!isAllowedSoundCloudUrl(u), u);
});

test('transcoding preference', () => {
  const prog = { url: 'p', format: { protocol: 'progressive', mime_type: 'audio/mpeg' } };
  const hlsMp3 = { url: 'h', format: { protocol: 'hls', mime_type: 'audio/mpeg' } };
  const hlsAac = { url: 'a', format: { protocol: 'hls', mime_type: 'audio/mp4; codecs="mp4a.40.2"' } };
  assert.deepStrictEqual(pickTranscoding([hlsAac, hlsMp3, prog]), { t: prog, copy: true });
  assert.deepStrictEqual(pickTranscoding([hlsAac, hlsMp3]), { t: hlsMp3, copy: true });
  assert.deepStrictEqual(pickTranscoding([hlsAac]), { t: hlsAac, copy: false });
  assert.strictEqual(pickTranscoding([]), null);
});

test('safeFilename', () => {
  assert.strictEqual(safeFilename('AC/DC - a\\b:c'), 'AC_DC - a_b_c');
  assert.strictEqual(safeFilename('a\u0000b\u001fc\n'), 'abc');
  assert.strictEqual(safeFilename(''), 'track');
  assert.strictEqual(safeFilename('  ...  '), 'track');
  assert.strictEqual(safeFilename(undefined), 'track');
});

test('audio/mpegurl is not mp3', () => {
  const abr = { url: 'x', format: { protocol: 'hls', mime_type: 'audio/mpegurl' } };
  assert.strictEqual(pickTranscoding([abr]), null);
  const aac = { url: 'y', format: { protocol: 'hls', mime_type: 'audio/mp4; codecs="mp4a.40.2"' } };
  assert.strictEqual(pickTranscoding([abr, aac]).t, aac); // fallback skips abr_sq
  assert.strictEqual(pickTranscoding([abr]), null);
});

test('zip is valid and keeps utf-8 names', () => {
  const file = path.join(os.tmpdir(), `downcloud-test-${process.pid}.zip`);
  fs.writeFileSync(file, zipEntries([{ name: '01 - a.mp3', data: Buffer.from('hello') }, { name: '02 - Bjork \u2013 Vespertine \u00e9.mp3', data: Buffer.from('world!') }]));
  try {
    assert.strictEqual(spawnSync('unzip', ['-t', file]).status, 0);
    const l = spawnSync('unzip', ['-l', file], { encoding: 'utf8' }).stdout;
    assert.ok(l.includes('01 - a.mp3') && l.includes('Vespertine'), l);
  } finally { fs.rmSync(file, { force: true }); }
});
