import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { pcm16ToFloat32 } from "../src/main/audio/pcm.js";

const fromInt16 = (values) => {
  const buffer = Buffer.alloc(values.length * 2);
  values.forEach((value, i) => buffer.writeInt16LE(value, i * 2));
  return buffer;
};

describe("pcm16ToFloat32", () => {
  test("scales signed 16-bit samples by 1/32768", () => {
    const samples = pcm16ToFloat32(fromInt16([0, 1, -1, 32767, -32768]));
    assert.ok(samples instanceof Float32Array);
    assert.deepEqual(
      [...samples],
      [0, 1 / 32768, -1 / 32768, 32767 / 32768, -1],
    );
  });

  test("reads the low byte first", () => {
    const samples = pcm16ToFloat32(Buffer.from([0x01, 0x00, 0x00, 0x01]));
    assert.deepEqual([...samples], [1 / 32768, 256 / 32768]);
  });

  test("ignores a trailing odd byte", () => {
    const samples = pcm16ToFloat32(Buffer.from([0x00, 0x40, 0xff]));
    assert.deepEqual([...samples], [0.5]);
  });

  test("returns no samples for empty or single-byte input", () => {
    assert.equal(pcm16ToFloat32(Buffer.alloc(0)).length, 0);
    assert.equal(pcm16ToFloat32(Buffer.from([0x7f])).length, 0);
  });

  test("decodes a Buffer that starts at an odd offset in its ArrayBuffer", () => {
    const arrayBuffer = new ArrayBuffer(7);
    new Uint8Array(arrayBuffer).set([0xaa, 0x00, 0x80, 0xff, 0x7f, 0x00, 0x40]);
    const pcm = Buffer.from(arrayBuffer, 1, 6);
    assert.equal(pcm.byteOffset % 2, 1);
    assert.deepEqual([...pcm16ToFloat32(pcm)], [-1, 32767 / 32768, 0.5]);
    assert.deepEqual(
      [...pcm16ToFloat32(Buffer.from([0xaa, 0x00, 0x80]).subarray(1))],
      [-1],
    );
  });
});
