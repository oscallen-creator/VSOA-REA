// Minimal ZIP writer for the "zip" output format (color.jpg + alpha.png).
// STORE only: the entries are already-compressed images, so deflate would
// cost time for nothing. No ZIP64, and a fixed DOS timestamp so identical
// input always yields identical bytes.

import { crc32 } from "node:zlib";

const LOCAL_HEADER_SIGNATURE = 0x04034b50;
const CENTRAL_HEADER_SIGNATURE = 0x02014b50;
const END_RECORD_SIGNATURE = 0x06054b50;

const LOCAL_HEADER_BYTES = 30;
const CENTRAL_HEADER_BYTES = 46;
const END_RECORD_BYTES = 22;

const MAX_ENTRIES = 0xffff;
const MAX_NAME_BYTES = 0xffff;
/** Sizes and offsets are 32-bit fields; anything larger needs ZIP64. */
const MAX_UINT32 = 0xffffffff;

const VERSION = 20;
/** General purpose bit 11: the entry name is UTF-8. */
const UTF8_NAMES = 0x0800;
const METHOD_STORE = 0;
const DOS_TIME = 0;
/** 1980-01-01, the DOS epoch: (year - 1980) << 9 | month << 5 | day. */
const DOS_DATE = (0 << 9) | (1 << 5) | 1;

const cursor = (buffer) => {
  let offset = 0;
  return {
    u16: (value) => {
      offset = buffer.writeUInt16LE(value, offset);
    },
    u32: (value) => {
      offset = buffer.writeUInt32LE(value, offset);
    },
    bytes: (source) => {
      buffer.set(source, offset);
      offset += source.length;
    },
  };
};

const assertSafeName = (name) => {
  if (typeof name !== "string" || name === "") {
    throw new Error("ZIP entry names must be non-empty strings.");
  }
  if (name.includes("\\") || name.includes("\0")) {
    throw new Error(`Unsafe ZIP entry name ${JSON.stringify(name)}.`);
  }
  // A leading slash or a ".." segment would escape the extraction folder.
  if (name.startsWith("/") || name.split("/").includes("..")) {
    throw new Error(`Unsafe ZIP entry name ${JSON.stringify(name)}.`);
  }
};

const prepareEntry = ({ name, data }) => {
  assertSafeName(name);
  const nameBytes = Buffer.from(name, "utf8");
  if (nameBytes.length > MAX_NAME_BYTES) {
    throw new RangeError(
      `ZIP entry name is too long (${nameBytes.length} bytes).`,
    );
  }
  if (!(data instanceof Uint8Array)) {
    throw new TypeError(`ZIP entry ${JSON.stringify(name)} needs Buffer data.`);
  }
  if (data.length > MAX_UINT32) {
    throw new RangeError(
      `ZIP entry ${JSON.stringify(name)} is 4 GiB or larger; ZIP64 is not supported.`,
    );
  }
  return { nameBytes, data };
};

const writeLocalHeader = (out, { nameBytes, data, crc }) => {
  out.u32(LOCAL_HEADER_SIGNATURE);
  out.u16(VERSION);
  out.u16(UTF8_NAMES);
  out.u16(METHOD_STORE);
  out.u16(DOS_TIME);
  out.u16(DOS_DATE);
  out.u32(crc);
  out.u32(data.length);
  out.u32(data.length);
  out.u16(nameBytes.length);
  out.u16(0);
  out.bytes(nameBytes);
  out.bytes(data);
};

const writeCentralHeader = (out, { nameBytes, data, crc, offset }) => {
  out.u32(CENTRAL_HEADER_SIGNATURE);
  out.u16(VERSION);
  out.u16(VERSION);
  out.u16(UTF8_NAMES);
  out.u16(METHOD_STORE);
  out.u16(DOS_TIME);
  out.u16(DOS_DATE);
  out.u32(crc);
  out.u32(data.length);
  out.u32(data.length);
  out.u16(nameBytes.length);
  out.u16(0); // extra field length
  out.u16(0); // comment length
  out.u16(0); // disk number start
  out.u16(0); // internal attributes
  out.u32(0); // external attributes
  out.u32(offset);
  out.bytes(nameBytes);
};

export const createZip = (entries) => {
  if (!Array.isArray(entries)) {
    throw new TypeError("ZIP entries must be an array.");
  }
  // Checked before touching any entry so an absurd list fails immediately.
  if (entries.length > MAX_ENTRIES) {
    throw new RangeError(
      `A ZIP without ZIP64 holds at most ${MAX_ENTRIES} entries; got ${entries.length}.`,
    );
  }

  // Lay everything out before allocating or hashing anything.
  let localBytes = 0;
  let centralBytes = 0;
  const files = entries.map((entry) => {
    const file = { ...prepareEntry(entry), offset: localBytes };
    localBytes += LOCAL_HEADER_BYTES + file.nameBytes.length + file.data.length;
    centralBytes += CENTRAL_HEADER_BYTES + file.nameBytes.length;
    return file;
  });
  if (localBytes > MAX_UINT32) {
    throw new RangeError(
      "ZIP archive would reach 4 GiB; ZIP64 is not supported.",
    );
  }

  const buffer = Buffer.alloc(localBytes + centralBytes + END_RECORD_BYTES);
  const out = cursor(buffer);
  for (const file of files) {
    file.crc = crc32(file.data);
    writeLocalHeader(out, file);
  }
  for (const file of files) writeCentralHeader(out, file);

  out.u32(END_RECORD_SIGNATURE);
  out.u16(0); // this disk
  out.u16(0); // disk with the central directory
  out.u16(files.length);
  out.u16(files.length);
  out.u32(centralBytes);
  out.u32(localBytes);
  out.u16(0); // comment length
  return buffer;
};
