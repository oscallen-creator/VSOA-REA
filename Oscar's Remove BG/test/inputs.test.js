import { afterEach, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  rm,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  IMAGE_EXTENSIONS,
  MAX_INPUT_BYTES,
  Rejection,
  collectInputs,
  describeRejections,
} from "../src/main/inputs.js";

let root;
beforeEach(async () => {
  root = await mkdtemp(path.join(os.tmpdir(), "orbg-inputs-"));
});
afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

const at = (...parts) => path.join(root, ...parts);

/** Creates files (and their folders) from "a/b.jpg"-style relative names. */
const touch = async (...names) => {
  for (const name of names) {
    await mkdir(path.dirname(at(name)), { recursive: true });
    await writeFile(at(name), "x");
  }
};

const relatives = (result) => result.accepted.map((a) => a.relativePath);
const sources = (result) => result.accepted.map((a) => a.sourcePath);
const rejections = (result) =>
  result.rejected.map(({ sourcePath, reason }) => [sourcePath, reason]);

describe("collectInputs files", () => {
  test("loose files keep only their name as the relative path", async () => {
    await touch("one.jpg", "two.png");
    const result = await collectInputs([at("one.jpg"), at("two.png")]);
    assert.deepEqual(result, {
      accepted: [
        { sourcePath: at("one.jpg"), relativePath: "one.jpg" },
        { sourcePath: at("two.png"), relativePath: "two.png" },
      ],
      rejected: [],
    });
  });

  test("accepts every supported extension, case-insensitively", async () => {
    assert.deepEqual(
      [...IMAGE_EXTENSIONS],
      [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"],
    );
    const names = ["a.jpg", "b.JPEG", "c.PNG", "d.tif", "e.TiFf", "f.WebP"];
    await touch(...names);
    const result = await collectInputs(names.map((n) => at(n)));
    assert.deepEqual(relatives(result), names);
    assert.deepEqual(result.rejected, []);
  });

  test("rejects other types as wrong_type", async () => {
    const names = [
      "a.gif",
      "b.bmp",
      "c.heic",
      "d.psd",
      "e.txt",
      "noext",
      "png",
    ];
    await touch(...names, "f.jpg.zip");
    const paths = [...names, "f.jpg.zip"].map((n) => at(n));
    const result = await collectInputs(paths);
    assert.deepEqual(result.accepted, []);
    assert.deepEqual(
      rejections(result),
      paths.map((p) => [p, Rejection.WrongType]),
    );
  });

  test("resolves relative and non-normalized input paths", async () => {
    await touch("sub/a.jpg");
    const odd = path.join(root, "sub", "..", "sub", "a.jpg");
    const result = await collectInputs([odd]);
    assert.deepEqual(sources(result), [at("sub", "a.jpg")]);
  });

  test("returns empty results for no paths", async () => {
    assert.deepEqual(await collectInputs([]), { accepted: [], rejected: [] });
  });

  test("a missing path is rejected as unreadable", async () => {
    const result = await collectInputs([at("nope.jpg")]);
    assert.deepEqual(result.accepted, []);
    assert.deepEqual(rejections(result), [[at("nope.jpg"), "unreadable"]]);
  });

  test("a missing path does not stop later paths", async () => {
    await touch("ok.jpg");
    const result = await collectInputs([at("nope.jpg"), at("ok.jpg")]);
    assert.deepEqual(sources(result), [at("ok.jpg")]);
    assert.equal(result.rejected.length, 1);
  });

  test("a dropped symlink to a file is followed", async (t) => {
    await touch("real.jpg");
    try {
      await symlink(at("real.jpg"), at("link.jpg"));
    } catch {
      t.skip("symlinks unavailable");
      return;
    }
    const result = await collectInputs([at("link.jpg")]);
    assert.deepEqual(sources(result), [at("link.jpg")]);
  });
});

describe("collectInputs size limit", () => {
  const sparse = async (name, size) => {
    await writeFile(at(name), "");
    await truncate(at(name), size);
  };

  test("MAX_INPUT_BYTES is 200 MiB", () => {
    assert.equal(MAX_INPUT_BYTES, 200 * 1024 * 1024);
  });

  test("a file over the limit is rejected as too_large", async () => {
    await sparse("huge.jpg", MAX_INPUT_BYTES + 1);
    const result = await collectInputs([at("huge.jpg")]);
    assert.deepEqual(result.accepted, []);
    assert.deepEqual(rejections(result), [[at("huge.jpg"), "too_large"]]);
  });

  test("a file exactly at the limit is accepted", async () => {
    await sparse("edge.png", MAX_INPUT_BYTES);
    const result = await collectInputs([at("edge.png")]);
    assert.deepEqual(sources(result), [at("edge.png")]);
  });

  test("too-large files inside folders are rejected, small ones kept", async () => {
    await mkdir(at("Trip"));
    await sparse("Trip/huge.tif", MAX_INPUT_BYTES + 1);
    await touch("Trip/small.tif");
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), ["Trip/small.tif"]);
    assert.deepEqual(rejections(result), [
      [at("Trip", "huge.tif"), "too_large"],
    ]);
  });

  test("an oversized file with the wrong type is wrong_type", async () => {
    await sparse("huge.gif", MAX_INPUT_BYTES + 1);
    const result = await collectInputs([at("huge.gif")]);
    assert.deepEqual(rejections(result), [[at("huge.gif"), "wrong_type"]]);
  });
});

describe("collectInputs folders", () => {
  test("walks recursively and keeps the dropped folder's name", async () => {
    await touch("Trip/a.jpg", "Trip/sub/b.png", "Trip/sub/deep/c.webp");
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), [
      "Trip/a.jpg",
      "Trip/sub/b.png",
      "Trip/sub/deep/c.webp",
    ]);
    assert.deepEqual(sources(result), [
      at("Trip", "a.jpg"),
      at("Trip", "sub", "b.png"),
      at("Trip", "sub", "deep", "c.webp"),
    ]);
  });

  test("a trailing separator on the folder path changes nothing", async () => {
    await touch("Trip/a.jpg");
    const result = await collectInputs([`${at("Trip")}${path.sep}`]);
    assert.deepEqual(relatives(result), ["Trip/a.jpg"]);
  });

  test("entries are sorted by name regardless of creation order", async () => {
    await touch("Trip/c.png", "Trip/a.png", "Trip/b.png");
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), [
      "Trip/a.png",
      "Trip/b.png",
      "Trip/c.png",
    ]);
  });

  test("folders and files are interleaved in name order", async () => {
    await touch("T/c_dir/z.png", "T/b.png", "T/a_dir/y.png", "T/d.png");
    const result = await collectInputs([at("T")]);
    assert.deepEqual(relatives(result), [
      "T/a_dir/y.png",
      "T/b.png",
      "T/c_dir/z.png",
      "T/d.png",
    ]);
  });

  test("an empty folder yields nothing", async () => {
    await mkdir(at("Empty"));
    assert.deepEqual(await collectInputs([at("Empty")]), {
      accepted: [],
      rejected: [],
    });
  });

  test("non-image files inside a folder are rejected as wrong_type", async () => {
    await touch("Trip/a.jpg", "Trip/notes.txt", "Trip/sub/readme.md");
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), ["Trip/a.jpg"]);
    assert.deepEqual(rejections(result), [
      [at("Trip", "notes.txt"), "wrong_type"],
      [at("Trip", "sub", "readme.md"), "wrong_type"],
    ]);
  });

  test("two dropped folders keep their own names", async () => {
    await touch("A/x.jpg", "B/x.jpg");
    const result = await collectInputs([at("A"), at("B")]);
    assert.deepEqual(relatives(result), ["A/x.jpg", "B/x.jpg"]);
  });

  test("a folder and a loose file can be dropped together", async () => {
    await touch("Trip/a.jpg", "loose.png");
    const result = await collectInputs([at("loose.png"), at("Trip")]);
    assert.deepEqual(relatives(result), ["loose.png", "Trip/a.jpg"]);
  });

  test("a symlink cycle inside a folder is not followed", async (t) => {
    await touch("Trip/a.jpg");
    try {
      await symlink(at("Trip"), at("Trip", "loop"));
    } catch {
      t.skip("symlinks unavailable");
      return;
    }
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), ["Trip/a.jpg"]);
  });
});

describe("collectInputs hidden names", () => {
  test("skips dot-files and dot-folders inside a dropped folder", async () => {
    await touch(
      "Trip/a.jpg",
      "Trip/.hidden.jpg",
      "Trip/.secret/x.jpg",
      "Trip/sub/.also.png",
      "Trip/sub/.deep/y.png",
      "Trip/sub/b.png",
    );
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), ["Trip/a.jpg", "Trip/sub/b.png"]);
    assert.deepEqual(result.rejected, []);
  });

  test("skips a dropped dot-folder without rejecting anything", async () => {
    await touch(".cache/a.jpg", ".cache/sub/b.png");
    assert.deepEqual(await collectInputs([at(".cache")]), {
      accepted: [],
      rejected: [],
    });
  });

  test("hidden non-image files are skipped silently, not rejected", async () => {
    await touch("Trip/.DS_Store", "Trip/a.jpg");
    const result = await collectInputs([at("Trip")]);
    assert.deepEqual(relatives(result), ["Trip/a.jpg"]);
    assert.deepEqual(result.rejected, []);
  });

  test("skips a dot-file dropped directly", async () => {
    await touch(".hidden.jpg", "visible.jpg");
    const result = await collectInputs([at(".hidden.jpg"), at("visible.jpg")]);
    assert.deepEqual(relatives(result), ["visible.jpg"]);
  });
});

describe("collectInputs duplicates", () => {
  test("sources already in the list are rejected as already_added", async () => {
    await touch("a.jpg", "b.jpg");
    const known = new Set([at("a.jpg")]);
    const result = await collectInputs([at("a.jpg"), at("b.jpg")], known);
    assert.deepEqual(sources(result), [at("b.jpg")]);
    assert.deepEqual(rejections(result), [[at("a.jpg"), "already_added"]]);
  });

  test("a path repeated in one call is added once", async () => {
    await touch("a.jpg");
    const result = await collectInputs([at("a.jpg"), at("a.jpg")]);
    assert.deepEqual(sources(result), [at("a.jpg")]);
    assert.deepEqual(rejections(result), [[at("a.jpg"), "already_added"]]);
  });

  test("a file also reached through a dropped folder is added once", async () => {
    await touch("Trip/a.jpg", "Trip/b.jpg");
    const result = await collectInputs([at("Trip", "a.jpg"), at("Trip")]);
    assert.deepEqual(relatives(result), ["a.jpg", "Trip/b.jpg"]);
    assert.deepEqual(rejections(result), [
      [at("Trip", "a.jpg"), "already_added"],
    ]);
  });

  test("equivalent spellings of one path are the same source", async () => {
    await touch("sub/a.jpg");
    const result = await collectInputs([
      at("sub", "a.jpg"),
      path.join(root, "sub", "..", "sub", "a.jpg"),
    ]);
    assert.equal(result.accepted.length, 1);
    assert.equal(result.rejected.length, 1);
  });

  test("does not mutate the known set", async () => {
    await touch("a.jpg");
    const known = new Set();
    await collectInputs([at("a.jpg")], known);
    assert.equal(known.size, 0);
  });

  test("dropping the same folder twice rejects every file as already_added", async () => {
    await touch("Trip/a.jpg", "Trip/b.jpg");
    const first = await collectInputs([at("Trip")]);
    const known = new Set(sources(first));
    const again = await collectInputs([at("Trip")], known);
    assert.deepEqual(again.accepted, []);
    assert.deepEqual(
      again.rejected.map(({ reason }) => reason),
      ["already_added", "already_added"],
    );
  });
});

describe("describeRejections", () => {
  const rejected = (...reasons) =>
    reasons.map((reason, index) => ({ sourcePath: `/f${index}`, reason }));

  test("is null when nothing was rejected", () => {
    assert.equal(describeRejections(0, []), null);
    assert.equal(describeRejections(5, []), null);
  });

  test("all rejected, singular", () => {
    assert.equal(
      describeRejections(0, rejected(Rejection.WrongType)),
      "Could not add 1 image because it is not a JPG/PNG/TIFF/WEBP file.",
    );
  });

  test("all rejected, plural", () => {
    assert.equal(
      describeRejections(0, rejected(Rejection.WrongType, Rejection.WrongType)),
      "Could not add 2 images because they are not JPG/PNG/TIFF/WEBP files.",
    );
  });

  test("some added, one rejected", () => {
    assert.equal(
      describeRejections(3, rejected(Rejection.AlreadyAdded)),
      "3 images added, but 1 image could not be added because it is already in the list.",
    );
  });

  test("one added, several rejected", () => {
    assert.equal(
      describeRejections(1, rejected(Rejection.TooLarge, Rejection.TooLarge)),
      "1 image added, but 2 images could not be added because they are larger than 200 MB.",
    );
  });

  test("mixed reasons are joined with and/or in first-seen order", () => {
    assert.equal(
      describeRejections(
        0,
        rejected(Rejection.TooLarge, Rejection.WrongType, Rejection.TooLarge),
      ),
      "Could not add 3 images because they are larger than 200 MB and/or not JPG/PNG/TIFF/WEBP files.",
    );
  });

  test("three or more reasons chain and/or", () => {
    assert.equal(
      describeRejections(
        2,
        rejected(
          Rejection.WrongType,
          Rejection.AlreadyAdded,
          Rejection.Unreadable,
        ),
      ),
      "2 images added, but 3 images could not be added because they are not JPG/PNG/TIFF/WEBP files and/or already in the list and/or not readable.",
    );
  });

  test("unreadable has its own wording", () => {
    assert.equal(
      describeRejections(0, rejected(Rejection.Unreadable)),
      "Could not add 1 image because it is not readable.",
    );
  });

  test("works end to end with collectInputs output", async () => {
    await touch("Trip/a.jpg", "Trip/b.txt");
    const { accepted, rejected: bad } = await collectInputs([
      at("Trip"),
      at("gone.png"),
    ]);
    assert.equal(
      describeRejections(accepted.length, bad),
      "1 image added, but 2 images could not be added because they are not JPG/PNG/TIFF/WEBP files and/or not readable.",
    );
  });
});
