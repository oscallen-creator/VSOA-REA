import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { crc32 } from "node:zlib";
import { createZip } from "../src/engine/zip.js";

const run = promisify(execFile);

const LOCAL_HEADER_BYTES = 30;
const CENTRAL_HEADER_BYTES = 46;
const END_RECORD_BYTES = 22;
const UTF8_FLAG = 0x0800;
const DOS_EPOCH_DATE = 0x0021; // 1980-01-01

const sequentialBytes = (count, seed = 0) =>
  Buffer.from(Array.from({ length: count }, (_, i) => (i * 7 + seed) % 256));

// Stands in for a multi-gigabyte Buffer without allocating one: createZip must
// reject on size before it reads a single byte.
const pretendBuffer = (length) =>
  Object.defineProperty(Object.create(Buffer.prototype), "length", {
    value: length,
  });

const parseHeader = (zip, offset, fields) => {
  const header = {};
  let at = offset;
  for (const [name, bytes] of fields) {
    header[name] = bytes === 2 ? zip.readUInt16LE(at) : zip.readUInt32LE(at);
    at += bytes;
  }
  return { header, next: at };
};

const LOCAL_FIELDS = [
  ["signature", 4],
  ["version", 2],
  ["flags", 2],
  ["method", 2],
  ["time", 2],
  ["date", 2],
  ["crc", 4],
  ["compressedSize", 4],
  ["size", 4],
  ["nameLength", 2],
  ["extraLength", 2],
];

const CENTRAL_FIELDS = [
  ["signature", 4],
  ["versionMadeBy", 2],
  ["version", 2],
  ["flags", 2],
  ["method", 2],
  ["time", 2],
  ["date", 2],
  ["crc", 4],
  ["compressedSize", 4],
  ["size", 4],
  ["nameLength", 2],
  ["extraLength", 2],
  ["commentLength", 2],
  ["disk", 2],
  ["internalAttributes", 2],
  ["externalAttributes", 4],
  ["localOffset", 4],
];

const END_FIELDS = [
  ["signature", 4],
  ["disk", 2],
  ["centralDisk", 2],
  ["entriesOnDisk", 2],
  ["entries", 2],
  ["centralSize", 4],
  ["centralOffset", 4],
  ["commentLength", 2],
];

/** Reads the archive back with an independent parser. */
const parseZip = (zip) => {
  const { header: end } = parseHeader(
    zip,
    zip.length - END_RECORD_BYTES,
    END_FIELDS,
  );
  const entries = [];
  let at = end.centralOffset;
  for (let i = 0; i < end.entries; i++) {
    const { header: central, next } = parseHeader(zip, at, CENTRAL_FIELDS);
    const name = zip.toString("utf8", next, next + central.nameLength);
    const { header: local, next: dataStart } = parseHeader(
      zip,
      central.localOffset,
      LOCAL_FIELDS,
    );
    const localName = zip.toString(
      "utf8",
      dataStart,
      dataStart + local.nameLength,
    );
    const data = zip.subarray(
      dataStart + local.nameLength,
      dataStart + local.nameLength + local.size,
    );
    entries.push({ name, localName, central, local, data });
    at = next + central.nameLength;
  }
  return { end, entries, centralEnd: at };
};

describe("createZip structure", () => {
  const entries = [
    { name: "color.jpg", data: sequentialBytes(300, 1) },
    { name: "alpha.png", data: sequentialBytes(1024, 2) },
    { name: "notes/empty.txt", data: Buffer.alloc(0) },
    { name: "check.txt", data: Buffer.from("123456789") },
  ];

  test("is reproducible: identical input gives identical bytes", () => {
    assert.deepEqual(createZip(entries), createZip(entries));
  });

  test("lays out local entries, central directory and end record back to back", () => {
    const zip = createZip(entries);
    const { end, entries: parsed, centralEnd } = parseZip(zip);

    const localBytes = entries.reduce(
      (sum, { name, data }) =>
        sum + LOCAL_HEADER_BYTES + Buffer.byteLength(name) + data.length,
      0,
    );
    const centralBytes = entries.reduce(
      (sum, { name }) => sum + CENTRAL_HEADER_BYTES + Buffer.byteLength(name),
      0,
    );
    assert.deepEqual(
      { ...end },
      {
        signature: 0x06054b50,
        disk: 0,
        centralDisk: 0,
        entriesOnDisk: entries.length,
        entries: entries.length,
        centralSize: centralBytes,
        centralOffset: localBytes,
        commentLength: 0,
      },
    );
    assert.equal(centralEnd, localBytes + centralBytes);
    assert.equal(zip.length, centralEnd + END_RECORD_BYTES);
    assert.equal(parsed.length, entries.length);
  });

  test("stores names, bytes, CRC-32 and sizes consistently in both headers", () => {
    const { entries: parsed } = parseZip(createZip(entries));
    parsed.forEach(({ name, localName, central, local, data }, index) => {
      const source = entries[index];
      assert.equal(name, source.name);
      assert.equal(localName, source.name);
      assert.deepEqual(data, source.data);
      for (const header of [central, local]) {
        assert.equal(header.crc, crc32(source.data));
        assert.equal(header.size, source.data.length);
        assert.equal(header.compressedSize, source.data.length);
        assert.equal(header.method, 0);
        assert.equal(header.flags, UTF8_FLAG);
        assert.equal(header.time, 0);
        assert.equal(header.date, DOS_EPOCH_DATE);
        assert.equal(header.version, 20);
        assert.equal(header.extraLength, 0);
      }
      assert.equal(central.signature, 0x02014b50);
      assert.equal(local.signature, 0x04034b50);
      assert.equal(central.commentLength, 0);
      assert.equal(central.disk, 0);
    });
  });

  test("matches the published CRC-32 check value for '123456789'", () => {
    const { entries: parsed } = parseZip(createZip(entries));
    assert.equal(parsed[3].central.crc, 0xcbf43926);
  });

  test("points each central record at its own local header", () => {
    const { entries: parsed } = parseZip(createZip(entries));
    let expectedOffset = 0;
    parsed.forEach(({ central }, index) => {
      assert.equal(central.localOffset, expectedOffset);
      expectedOffset +=
        LOCAL_HEADER_BYTES +
        Buffer.byteLength(entries[index].name) +
        entries[index].data.length;
    });
  });
});

describe("createZip archives", () => {
  test("marks names as UTF-8 and round-trips non-ASCII names", () => {
    const names = ["données/été.txt", "写真.jpg", "emoji-\u{1f600}.bin"];
    const zip = createZip(
      names.map((name) => ({ name, data: Buffer.from(name) })),
    );
    const { entries: parsed } = parseZip(zip);
    assert.deepEqual(
      parsed.map(({ name }) => name),
      names,
    );
    for (const { central, local } of parsed) {
      assert.equal(central.flags & UTF8_FLAG, UTF8_FLAG);
      assert.equal(local.flags & UTF8_FLAG, UTF8_FLAG);
    }
  });

  test("writes only an end record for an empty archive", () => {
    const zip = createZip([]);
    assert.equal(zip.length, END_RECORD_BYTES);
    const { end } = parseZip(zip);
    assert.equal(end.signature, 0x06054b50);
    assert.equal(end.entries, 0);
    assert.equal(end.centralSize, 0);
    assert.equal(end.centralOffset, 0);
  });

  test("copies the data and accepts plain Uint8Array entries", () => {
    const data = Buffer.from([1, 2, 3, 4]);
    const zip = createZip([
      { name: "buffer.bin", data },
      { name: "view.bin", data: new Uint8Array([9, 8, 7]) },
    ]);
    data.fill(0);
    const { entries: parsed } = parseZip(zip);
    assert.deepEqual(parsed[0].data, Buffer.from([1, 2, 3, 4]));
    assert.deepEqual(parsed[1].data, Buffer.from([9, 8, 7]));
  });

  test("holds the maximum of 65535 entries", () => {
    const many = Array.from({ length: 65_535 }, (_, i) => ({
      name: `f${i}`,
      data: Buffer.alloc(0),
    }));
    const { end, entries: parsed } = parseZip(createZip(many));
    assert.equal(end.entries, 65_535);
    assert.equal(parsed.at(-1).name, "f65534");
  });
});

describe("createZip with the system unzip", () => {
  let dir;
  before(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "zip-test-"));
  });
  after(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  const entries = [
    { name: "color.jpg", data: sequentialBytes(5000, 3) },
    { name: "alpha.png", data: sequentialBytes(777, 4) },
    { name: "nested/dir/blob.bin", data: sequentialBytes(2048, 5) },
  ];

  test("lists entry names in order with unzip -Z1", async () => {
    const file = path.join(dir, "list.zip");
    await writeFile(file, createZip(entries));
    const { stdout } = await run("unzip", ["-Z1", file]);
    assert.deepEqual(
      stdout.trim().split("\n"),
      entries.map(({ name }) => name),
    );
  });

  test("extracts the exact bytes of every entry with unzip -p", async () => {
    const file = path.join(dir, "extract.zip");
    await writeFile(file, createZip(entries));
    for (const { name, data } of entries) {
      const { stdout } = await run("unzip", ["-p", file, name], {
        encoding: "buffer",
        maxBuffer: 1 << 20,
      });
      assert.deepEqual(stdout, data, name);
    }
  });

  test("passes unzip's CRC and structure test", async () => {
    const file = path.join(dir, "test.zip");
    await writeFile(file, createZip(entries));
    const { stdout } = await run("unzip", ["-t", file]);
    assert.match(stdout, /No errors detected/);
  });

  test("a flipped data byte fails unzip's CRC test", async () => {
    const zip = createZip(entries);
    zip[LOCAL_HEADER_BYTES + Buffer.byteLength(entries[0].name) + 10] ^= 0xff;
    const file = path.join(dir, "corrupt.zip");
    await writeFile(file, zip);
    await assert.rejects(
      run("unzip", ["-t", file]),
      (error) => error.code !== 0,
    );
  });
});

describe("createZip rejections", () => {
  const entryNamed = (name) => [{ name, data: Buffer.from("x") }];

  test("rejects empty and non-string names", () => {
    assert.throws(() => createZip(entryNamed("")), /non-empty/);
    assert.throws(() => createZip(entryNamed(undefined)), /non-empty/);
    assert.throws(() => createZip(entryNamed(42)), /non-empty/);
  });

  test("rejects names containing a backslash", () => {
    assert.throws(() => createZip(entryNamed("a\\b.txt")), /Unsafe/);
    assert.throws(() => createZip(entryNamed("..\\evil")), /Unsafe/);
  });

  test("rejects '..' segments", () => {
    for (const name of ["..", "../evil", "a/../evil", "a/..", "a/b/../../c"]) {
      assert.throws(() => createZip(entryNamed(name)), /Unsafe/, name);
    }
  });

  test("rejects a leading slash and embedded NUL", () => {
    assert.throws(() => createZip(entryNamed("/etc/passwd")), /Unsafe/);
    assert.throws(() => createZip(entryNamed("a\0b")), /Unsafe/);
  });

  test("accepts names that merely look similar", () => {
    const names = [
      "a..b.txt",
      "..hidden",
      "dir/file.txt",
      "a/./b",
      "trailing.",
    ];
    const { entries } = parseZip(
      createZip(names.map((name) => ({ name, data: Buffer.alloc(1) }))),
    );
    assert.deepEqual(
      entries.map(({ name }) => name),
      names,
    );
  });

  test("rejects names longer than 65535 UTF-8 bytes", () => {
    assert.throws(() => createZip(entryNamed("a".repeat(65_536))), /too long/);
    assert.doesNotThrow(() => createZip(entryNamed("a".repeat(65_535))));
  });

  test("rejects more than 65535 entries before looking at any of them", () => {
    const tooMany = Array.from({ length: 65_536 }, () => null);
    assert.throws(() => createZip(tooMany), /at most 65535/);
  });

  test("rejects a single entry of 4 GiB or more (no ZIP64)", () => {
    const entries = [{ name: "huge.bin", data: pretendBuffer(2 ** 32) }];
    assert.throws(() => createZip(entries), /4 GiB/);
  });

  test("rejects an archive whose offsets would pass 4 GiB", () => {
    const half = (name) => ({ name, data: pretendBuffer(2 ** 31) });
    assert.throws(() => createZip([half("a"), half("b"), half("c")]), /4 GiB/);
  });

  test("rejects malformed arguments", () => {
    assert.throws(() => createZip(null), /array/);
    assert.throws(
      () => createZip({ name: "a", data: Buffer.alloc(0) }),
      /array/,
    );
    assert.throws(
      () => createZip([{ name: "a.txt", data: "not bytes" }]),
      /Buffer data/,
    );
  });
});
