import {
  after,
  afterEach,
  before,
  beforeEach,
  describe,
  test,
} from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { once } from "node:events";
import {
  mkdtemp,
  readdir,
  readFile,
  rm,
  stat,
  utimes,
  writeFile,
} from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import {
  ModelDownloadError,
  defaultModelDir,
  ensureModel,
  modelPath,
} from "../src/engine/modelStore.js";

const sha256 = (buffer) => createHash("sha256").update(buffer).digest("hex");

const PAYLOAD = randomBytes(64 * 1024);
// Same length as PAYLOAD so only the hash (not the size) can reject it.
const WRONG = randomBytes(PAYLOAD.length);
const SECRET_BODY = "secret-response-body";

const hits = new Map();
const hitsFor = (name) => hits.get(name) ?? 0;

const serve = (res, body, { status = 200, headers = {} } = {}) => {
  res.writeHead(status, { "content-length": body.length, ...headers });
  res.end(body);
};

// Sends the body in `pieces` separate writes so the client sees several chunks
// and a cancelled client has time to hang up mid-transfer.
const servePaced = (res, body, { pieces, delayMs }) => {
  res.writeHead(200, { "content-length": body.length });
  const size = Math.ceil(body.length / pieces);
  let offset = 0;
  const timer = setInterval(() => {
    if (offset >= body.length) {
      clearInterval(timer);
      res.end();
      return;
    }
    res.write(body.subarray(offset, offset + size));
    offset += size;
  }, delayMs);
  res.on("close", () => clearInterval(timer));
};

const routes = {
  "ok.bin": (req, res) => serve(res, PAYLOAD),
  "wrong.bin": (req, res) => serve(res, WRONG),
  "long.bin": (req, res) =>
    serve(res, Buffer.concat([PAYLOAD, randomBytes(1024)])),
  "short.bin": (req, res) =>
    serve(res, PAYLOAD.subarray(0, PAYLOAD.length - 100)),
  "missing.bin": (req, res) => serve(res, SECRET_BODY, { status: 404 }),
  "redirect.bin": (req, res) =>
    serve(res, "", { status: 302, headers: { location: "/ok.bin" } }),
  "paced.bin": (req, res) =>
    servePaced(res, PAYLOAD, { pieces: 4, delayMs: 20 }),
  "slow.bin": (req, res) =>
    servePaced(res, PAYLOAD, { pieces: 16, delayMs: 30 }),
  "reset.bin": (req, res) => {
    res.writeHead(200, { "content-length": PAYLOAD.length });
    res.write(PAYLOAD.subarray(0, 8192));
    setTimeout(() => res.destroy(), 20);
  },
  // Corrupt on the first request, correct afterwards.
  "flaky.bin": (req, res) =>
    serve(res, hitsFor("flaky.bin") === 1 ? WRONG : PAYLOAD),
};

let server;
let baseUrl;
let dir;

before(async () => {
  server = http.createServer((req, res) => {
    const name = req.url.slice(1);
    hits.set(name, hitsFor(name) + 1);
    const route = routes[name];
    if (route) route(req, res);
    else serve(res, "", { status: 404 });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

beforeEach(async () => {
  hits.clear();
  dir = await mkdtemp(path.join(os.tmpdir(), "orbg-models-"));
});

afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const modelFor = (route, overrides = {}) => ({
  id: "test-net",
  url: `${baseUrl}/${route}`,
  sha256: sha256(PAYLOAD),
  bytes: PAYLOAD.length,
  ...overrides,
});

const readSidecar = async (file) =>
  JSON.parse(await readFile(`${file}.verified`, "utf8"));

const ageFile = async (file) => {
  const earlier = new Date(Date.now() - 3_600_000);
  await utimes(file, earlier, earlier);
};

// A fetch stand-in that answers every request with this body.
const respondWith = (body) => async () => new Response(body);

const rejectsWith = (promise, code) =>
  assert.rejects(promise, (error) => {
    assert.ok(error instanceof ModelDownloadError, String(error));
    assert.equal(error.code, code, error.message);
    assert.equal(error.modelId, "test-net");
    assert.match(error.url, /^http:\/\/127\.0\.0\.1:\d+\//);
    return true;
  });

describe("ensureModel download", () => {
  test("downloads, verifies and returns the absolute path", async () => {
    const nested = path.join(dir, "nested", "models");
    const model = modelFor("ok.bin");
    const file = await ensureModel(model, { dir: nested });
    assert.equal(file, path.resolve(modelPath(model, nested)));
    assert.ok(path.isAbsolute(file));
    assert.deepEqual(await readFile(file), PAYLOAD);
    assert.equal(hitsFor("ok.bin"), 1);
    // No leftover .partial- file, and the sidecar describes the final file.
    assert.deepEqual((await readdir(nested)).sort(), [
      "test-net.onnx",
      "test-net.onnx.verified",
    ]);
    assert.deepEqual(await readSidecar(file), {
      sha256: model.sha256,
      bytes: model.bytes,
      mtimeMs: (await stat(file)).mtimeMs,
    });
  });

  test("follows redirects", async () => {
    const file = await ensureModel(modelFor("redirect.bin"), { dir });
    assert.deepEqual(await readFile(file), PAYLOAD);
    assert.equal(hitsFor("redirect.bin"), 1);
    assert.equal(hitsFor("ok.bin"), 1);
  });

  for (const [name, content] of [
    ["the wrong size", "truncated"],
    ["the right size but wrong content", WRONG],
  ]) {
    test(`replaces an existing file with ${name}`, async () => {
      const model = modelFor("ok.bin");
      const file = modelPath(model, dir);
      await writeFile(file, content);
      assert.equal(await ensureModel(model, { dir }), file);
      assert.deepEqual(await readFile(file), PAYLOAD);
      assert.equal(hitsFor("ok.bin"), 1);
      assert.deepEqual((await readdir(dir)).sort(), [
        "test-net.onnx",
        "test-net.onnx.verified",
      ]);
    });
  }
});

describe("ensureModel cache", () => {
  test("a second call returns the same path without a request", async () => {
    const model = modelFor("ok.bin");
    const first = await ensureModel(model, { dir });
    const calls = [];
    const second = await ensureModel(model, {
      dir,
      onProgress: (progress) => calls.push(progress),
    });
    assert.equal(second, first);
    assert.equal(hitsFor("ok.bin"), 1);
    assert.deepEqual(calls, []);
  });

  test("trusts a matching sidecar without hashing the file", async () => {
    const model = modelFor("ok.bin");
    const file = await ensureModel(model, { dir });
    // Same size, different bytes: only hashing would notice.
    await writeFile(file, WRONG);
    const { mtimeMs } = await stat(file);
    await writeFile(
      `${file}.verified`,
      JSON.stringify({ sha256: model.sha256, bytes: model.bytes, mtimeMs }),
    );
    assert.equal(await ensureModel(model, { dir }), file);
    assert.equal(hitsFor("ok.bin"), 1);
    assert.deepEqual(await readFile(file), WRONG);
  });

  test("re-verifies and re-downloads when the file changed after the sidecar", async () => {
    const model = modelFor("ok.bin");
    const file = await ensureModel(model, { dir });
    await writeFile(file, WRONG);
    await ageFile(file);
    assert.equal(await ensureModel(model, { dir }), file);
    assert.deepEqual(await readFile(file), PAYLOAD);
    assert.equal(hitsFor("ok.bin"), 2);
    assert.equal((await readSidecar(file)).mtimeMs, (await stat(file)).mtimeMs);
  });

  test("re-hashes a stale sidecar and rewrites it when the file is intact", async () => {
    const model = modelFor("ok.bin");
    const file = await ensureModel(model, { dir });
    await ageFile(file);
    assert.equal(await ensureModel(model, { dir }), file);
    assert.equal(hitsFor("ok.bin"), 1);
    assert.equal((await readSidecar(file)).mtimeMs, (await stat(file)).mtimeMs);
  });

  for (const [name, contents] of [
    ["missing", null],
    ["not JSON", "{{{"],
    ["null", "null"],
    ["incomplete", '{"sha256":"abc"}'],
  ]) {
    test(`re-hashes and rewrites a sidecar that is ${name}`, async () => {
      const model = modelFor("ok.bin");
      const file = await ensureModel(model, { dir });
      const expected = await readSidecar(file);
      if (contents === null) await rm(`${file}.verified`);
      else await writeFile(`${file}.verified`, contents);
      assert.equal(await ensureModel(model, { dir }), file);
      assert.equal(hitsFor("ok.bin"), 1);
      assert.deepEqual(await readSidecar(file), expected);
    });
  }

  test("a sidecar for a different pinned hash does not vouch for the file", async () => {
    const file = await ensureModel(modelFor("ok.bin"), { dir });
    const updated = modelFor("wrong.bin", { sha256: sha256(WRONG) });
    assert.equal(await ensureModel(updated, { dir }), file);
    assert.deepEqual(await readFile(file), WRONG);
    assert.equal(hitsFor("wrong.bin"), 1);
  });
});

describe("ensureModel rejected responses", () => {
  test("rejects a hash mismatch and leaves nothing behind", async () => {
    await rejectsWith(
      ensureModel(modelFor("wrong.bin"), { dir }),
      "hash_mismatch",
    );
    assert.deepEqual(await readdir(dir), []);
  });

  test("rejects a server that sends more bytes than expected", async () => {
    await rejectsWith(
      ensureModel(modelFor("long.bin"), { dir }),
      "size_mismatch",
    );
    assert.deepEqual(await readdir(dir), []);
  });

  test("cancels an endless stream instead of buffering it", async () => {
    let pulls = 0;
    let cancelledByClient = false;
    const chunk = new Uint8Array(16 * 1024);
    const endless = new ReadableStream({
      pull(controller) {
        pulls += 1;
        controller.enqueue(chunk);
      },
      cancel() {
        cancelledByClient = true;
      },
    });
    await rejectsWith(
      ensureModel(modelFor("unused"), { dir, fetch: respondWith(endless) }),
      "size_mismatch",
    );
    assert.ok(cancelledByClient);
    assert.ok(pulls < 20, `pulled ${pulls} chunks`);
    assert.deepEqual(await readdir(dir), []);
  });

  test("rejects a server that sends fewer bytes than expected", async () => {
    await rejectsWith(
      ensureModel(modelFor("short.bin"), { dir }),
      "size_mismatch",
    );
    assert.deepEqual(await readdir(dir), []);
  });

  test("rejects an empty body as a size mismatch", async () => {
    await rejectsWith(
      ensureModel(modelFor("unused"), { dir, fetch: respondWith(null) }),
      "size_mismatch",
    );
  });

  test("reports HTTP 404 without echoing the response body", async () => {
    await assert.rejects(
      ensureModel(modelFor("missing.bin"), { dir }),
      (error) => {
        assert.ok(error instanceof ModelDownloadError);
        assert.equal(error.code, "http_status");
        assert.match(error.message, /404/);
        assert.ok(!error.message.includes(SECRET_BODY));
        return true;
      },
    );
    assert.deepEqual(await readdir(dir), []);
  });
});

describe("ensureModel transport failures", () => {
  test("maps a connection failure to network", async () => {
    const refused = async () => {
      throw new TypeError("fetch failed", {
        cause: Object.assign(new Error("connect ECONNREFUSED"), {
          code: "ECONNREFUSED",
        }),
      });
    };
    await assert.rejects(
      ensureModel(modelFor("unused"), { dir, fetch: refused }),
      (error) => {
        assert.ok(error instanceof ModelDownloadError);
        assert.equal(error.code, "network");
        assert.match(error.message, /ECONNREFUSED/);
        return true;
      },
    );
  });

  test("maps a connection dropped mid-transfer to network and removes the partial", async () => {
    await rejectsWith(ensureModel(modelFor("reset.bin"), { dir }), "network");
    assert.deepEqual(await readdir(dir), []);
  });

  test("a failed download does not block a later retry", async () => {
    const model = modelFor("flaky.bin");
    await rejectsWith(ensureModel(model, { dir }), "hash_mismatch");
    const file = await ensureModel(model, { dir });
    assert.deepEqual(await readFile(file), PAYLOAD);
    assert.equal(hitsFor("flaky.bin"), 2);
  });

  test("rejects invalid descriptors without a request", async () => {
    for (const [overrides, message] of [
      [{ id: "../evil" }, /Invalid model id/],
      [{ sha256: "ABC" }, /sha256/],
      [{ bytes: 0 }, /byte size/],
      [{ url: "" }, /url/],
    ]) {
      await assert.rejects(
        ensureModel(modelFor("ok.bin", overrides), { dir }),
        message,
      );
    }
    assert.equal(hitsFor("ok.bin"), 0);
  });
});

describe("ensureModel cancellation", () => {
  test("aborting from onProgress stops the download and removes the partial", async () => {
    const controller = new AbortController();
    await rejectsWith(
      ensureModel(modelFor("slow.bin"), {
        dir,
        signal: controller.signal,
        onProgress: () => controller.abort(),
      }),
      "aborted",
    );
    assert.deepEqual(await readdir(dir), []);
  });

  test("aborting while waiting for data rejects with aborted", async () => {
    const controller = new AbortController();
    const pending = ensureModel(modelFor("slow.bin"), {
      dir,
      signal: controller.signal,
    });
    setTimeout(() => controller.abort(), 100);
    await rejectsWith(pending, "aborted");
    assert.deepEqual(await readdir(dir), []);
  });

  test("an already aborted signal rejects without a request, and a retry works", async () => {
    const model = modelFor("ok.bin");
    await rejectsWith(
      ensureModel(model, { dir, signal: AbortSignal.abort() }),
      "aborted",
    );
    assert.equal(hitsFor("ok.bin"), 0);
    assert.deepEqual(await readdir(dir), []);
    assert.deepEqual(
      await readFile(await ensureModel(model, { dir })),
      PAYLOAD,
    );
  });
});

describe("ensureModel sharing", () => {
  test("concurrent calls for one path share a download; other paths do not", async () => {
    const model = modelFor("paced.bin");
    const [a, b, other] = await Promise.all([
      ensureModel(model, { dir }),
      ensureModel(model, { dir }),
      ensureModel(model, { dir: path.join(dir, "other") }),
    ]);
    assert.equal(a, b);
    assert.notEqual(a, other);
    assert.equal(hitsFor("paced.bin"), 2);
    assert.deepEqual(await readFile(a), PAYLOAD);
    assert.equal(await ensureModel(model, { dir }), a);
    assert.equal(hitsFor("paced.bin"), 2);
  });
});

describe("ensureModel progress", () => {
  test("reports increasing byte counts and ends at the total", async () => {
    const calls = [];
    await ensureModel(modelFor("paced.bin"), {
      dir,
      onProgress: (progress) => calls.push(progress),
    });
    assert.ok(calls.length > 1, `got ${calls.length} progress calls`);
    for (const { total } of calls) assert.equal(total, PAYLOAD.length);
    for (let i = 1; i < calls.length; i += 1) {
      assert.ok(calls[i].received > calls[i - 1].received);
    }
    assert.equal(calls.at(-1).received, PAYLOAD.length);
  });

  test("reports at most once per percent for many tiny chunks", async () => {
    const tiny = new ReadableStream({
      start(controller) {
        for (let offset = 0; offset < PAYLOAD.length; offset += 64) {
          controller.enqueue(PAYLOAD.subarray(offset, offset + 64));
        }
        controller.close();
      },
    });
    const received = [];
    await ensureModel(modelFor("unused"), {
      dir,
      fetch: respondWith(tiny),
      onProgress: (progress) => received.push(progress.received),
    });
    assert.ok(received.length > 1);
    assert.ok(received.length <= 100, `got ${received.length} progress calls`);
    assert.equal(received.at(-1), PAYLOAD.length);
    assert.equal(new Set(received).size, received.length);
  });

  test("a throwing progress listener does not fail the download", async () => {
    const file = await ensureModel(modelFor("paced.bin"), {
      dir,
      onProgress: () => {
        throw new Error("listener bug");
      },
    });
    assert.deepEqual(await readFile(file), PAYLOAD);
  });
});

describe("defaultModelDir", () => {
  const dirFor = (platform, env, homedir = "/home/oscar") =>
    defaultModelDir({ env, platform, homedir });

  test("OSCARS_REMOVE_BG_MODELS overrides every platform", () => {
    const env = { OSCARS_REMOVE_BG_MODELS: "/data/models", LOCALAPPDATA: "C:" };
    for (const platform of ["win32", "darwin", "linux"]) {
      assert.equal(dirFor(platform, env), "/data/models");
    }
  });

  test("windows uses LOCALAPPDATA", () => {
    assert.equal(
      dirFor("win32", { LOCALAPPDATA: "D:\\Local" }, "C:\\Users\\Oscar"),
      "D:\\Local\\Oscar's Remove BG\\models",
    );
  });

  test("windows falls back to AppData\\Local under the home directory", () => {
    assert.equal(
      dirFor("win32", {}, "C:\\Users\\Oscar"),
      "C:\\Users\\Oscar\\AppData\\Local\\Oscar's Remove BG\\models",
    );
  });

  test("macOS uses Application Support", () => {
    assert.equal(
      dirFor("darwin", {}, "/Users/oscar"),
      "/Users/oscar/Library/Application Support/Oscar's Remove BG/models",
    );
  });

  test("linux uses XDG_CACHE_HOME when set", () => {
    assert.equal(
      dirFor("linux", { XDG_CACHE_HOME: "/var/cache/oscar" }),
      "/var/cache/oscar/oscars-remove-bg/models",
    );
  });

  test("linux falls back to ~/.cache, treating empty values as unset", () => {
    const expected = "/home/oscar/.cache/oscars-remove-bg/models";
    assert.equal(dirFor("linux", {}), expected);
    const empty = { OSCARS_REMOVE_BG_MODELS: "", XDG_CACHE_HOME: "" };
    assert.equal(dirFor("linux", empty), expected);
  });
});

describe("modelPath", () => {
  test("joins the directory and <id>.onnx", () => {
    assert.equal(
      modelPath({ id: "u2netp" }, "models"),
      path.join("models", "u2netp.onnx"),
    );
  });

  test("accepts lowercase ids with digits, dots, dashes and underscores", () => {
    for (const id of ["u2netp", "isnet-general-use", "birefnet_v2.1", "0abc"]) {
      assert.equal(modelPath({ id }, "m"), path.join("m", `${id}.onnx`));
    }
  });

  test("rejects ids that could escape the directory or are malformed", () => {
    const bad = ["../evil", "A B", "", "a/b", "a\\b", ".dot", "-x", "UP"];
    for (const id of [...bad, undefined, 42]) {
      assert.throws(() => modelPath({ id }, "m"), /Invalid model id/);
    }
  });
});
