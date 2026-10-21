import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { encodeWav, pcmDurationMs } from "../src/main/audio/wav.js";
import {
  RECORDER_CHUNK_SAMPLES,
  RECORDING_SAMPLE_RATE,
} from "../src/main/constants.js";

const HEADER_BYTES = 44;

const readHeader = (wav) => ({
  riff: wav.toString("ascii", 0, 4),
  riffSize: wav.readUInt32LE(4),
  wave: wav.toString("ascii", 8, 12),
  fmt: wav.toString("ascii", 12, 16),
  fmtSize: wav.readUInt32LE(16),
  audioFormat: wav.readUInt16LE(20),
  channels: wav.readUInt16LE(22),
  sampleRate: wav.readUInt32LE(24),
  byteRate: wav.readUInt32LE(28),
  blockAlign: wav.readUInt16LE(32),
  bitsPerSample: wav.readUInt16LE(34),
  data: wav.toString("ascii", 36, 40),
  dataSize: wav.readUInt32LE(40),
});

const sequentialBytes = (count) =>
  Buffer.from(Array.from({ length: count }, (_, i) => i % 256));

describe("encodeWav", () => {
  test("writes a 44-byte mono 16-bit PCM header", () => {
    const wav = encodeWav(Buffer.from([1, 2, 3, 4, 5, 6]), 16_000);
    assert.equal(wav.length, HEADER_BYTES + 6);
    assert.deepEqual(readHeader(wav), {
      riff: "RIFF",
      riffSize: 36 + 6,
      wave: "WAVE",
      fmt: "fmt ",
      fmtSize: 16,
      audioFormat: 1,
      channels: 1,
      sampleRate: 16_000,
      byteRate: 32_000,
      blockAlign: 2,
      bitsPerSample: 16,
      data: "data",
      dataSize: 6,
    });
  });

  test("appends the PCM payload unchanged", () => {
    const pcm = sequentialBytes(1000);
    const wav = encodeWav(pcm, 16_000);
    assert.equal(wav.length, HEADER_BYTES + pcm.length);
    assert.deepEqual(wav.subarray(HEADER_BYTES), pcm);
  });

  test("derives the byte rate from the sample rate", () => {
    for (const rate of [8_000, 16_000, 22_050, 44_100, 48_000]) {
      const header = readHeader(encodeWav(Buffer.alloc(4), rate));
      assert.equal(header.sampleRate, rate);
      assert.equal(header.byteRate, rate * 2);
    }
  });

  test("encodes empty audio as a header-only file", () => {
    const wav = encodeWav(Buffer.alloc(0), 16_000);
    assert.equal(wav.length, HEADER_BYTES);
    const header = readHeader(wav);
    assert.equal(header.riffSize, 36);
    assert.equal(header.dataSize, 0);
  });

  test("sizes one recorder chunk (640 samples) correctly", () => {
    const pcm = Buffer.alloc(RECORDER_CHUNK_SAMPLES * 2);
    const header = readHeader(encodeWav(pcm, RECORDING_SAMPLE_RATE));
    assert.equal(header.dataSize, 1280);
    assert.equal(header.riffSize, 1280 + 36);
  });

  test("accepts a plain Uint8Array and a Buffer view with a byte offset", () => {
    const fromUint8 = encodeWav(new Uint8Array([9, 8, 7, 6]), 16_000);
    assert.deepEqual(
      fromUint8.subarray(HEADER_BYTES),
      Buffer.from([9, 8, 7, 6]),
    );
    const backing = Buffer.from([0xff, 0xff, 1, 2, 3, 4, 0xff]);
    const fromView = encodeWav(backing.subarray(2, 6), 16_000);
    assert.equal(readHeader(fromView).dataSize, 4);
    assert.deepEqual(
      fromView.subarray(HEADER_BYTES),
      Buffer.from([1, 2, 3, 4]),
    );
  });

  test("returns an independent Buffer rather than aliasing the input", () => {
    const pcm = Buffer.from([1, 2, 3, 4]);
    const wav = encodeWav(pcm, 16_000);
    assert.ok(Buffer.isBuffer(wav));
    wav[HEADER_BYTES] = 99;
    assert.equal(pcm[0], 1);
  });
});

describe("pcmDurationMs", () => {
  test("32,000 bytes at 16 kHz is one second", () => {
    assert.equal(pcmDurationMs(Buffer.alloc(32_000), 16_000), 1000);
  });

  test("one recorder chunk (1,280 bytes at 16 kHz) is 40 ms", () => {
    assert.equal(
      pcmDurationMs(
        Buffer.alloc(RECORDER_CHUNK_SAMPLES * 2),
        RECORDING_SAMPLE_RATE,
      ),
      40,
    );
  });

  test("empty audio has zero duration", () => {
    assert.equal(pcmDurationMs(Buffer.alloc(0), 16_000), 0);
  });

  test("scales with the sample rate and accepts a Uint8Array", () => {
    assert.equal(pcmDurationMs(new Uint8Array(16_000), 8_000), 1000);
    assert.equal(pcmDurationMs(new Uint8Array(96_000), 48_000), 1000);
  });

  test("agrees with the duration implied by the encoded WAV header", () => {
    const pcm = sequentialBytes(48_000);
    const header = readHeader(encodeWav(pcm, 16_000));
    assert.equal(
      (header.dataSize / header.byteRate) * 1000,
      pcmDurationMs(pcm, 16_000),
    );
  });
});
