import { describe, test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { outputFormat, resultPath } from "../src/main/outputPath.js";

const OUT = path.join(path.sep, "home", "oscar", "Pictures", "Out");

describe("outputFormat", () => {
  test("color backgrounds always produce jpg", () => {
    assert.equal(outputFormat({ bgMode: "color", usePsd: false }), "jpg");
    assert.equal(outputFormat({ bgMode: "color", usePsd: true }), "jpg");
  });

  test("transparent produces png, or psd with the Photoshop option", () => {
    assert.equal(outputFormat({ bgMode: "transparent", usePsd: false }), "png");
    assert.equal(outputFormat({ bgMode: "transparent", usePsd: true }), "psd");
  });

  test("ignores unrelated settings keys", () => {
    const settings = { bgMode: "transparent", usePsd: false, quality: "fast" };
    assert.equal(outputFormat(settings), "png");
  });
});

describe("resultPath extension", () => {
  test("replaces the extension with the output format", () => {
    assert.equal(
      resultPath(OUT, "beach.jpeg", "png"),
      path.join(OUT, "beach.png"),
    );
    assert.equal(resultPath(OUT, "a.webp", "jpg"), path.join(OUT, "a.jpg"));
    assert.equal(resultPath(OUT, "a.tif", "psd"), path.join(OUT, "a.psd"));
  });

  test("replaces only the last extension", () => {
    assert.equal(resultPath(OUT, "a.b.jpg", "png"), path.join(OUT, "a.b.png"));
    assert.equal(
      resultPath(OUT, "archive.tar.gz", "png"),
      path.join(OUT, "archive.tar.png"),
    );
  });

  test("adds an extension to extension-less names", () => {
    assert.equal(resultPath(OUT, "photo", "png"), path.join(OUT, "photo.png"));
    assert.equal(
      resultPath(OUT, "Trip/photo", "jpg"),
      path.join(OUT, "Trip", "photo.jpg"),
    );
  });

  test("a dot in a folder name is not mistaken for an extension", () => {
    assert.equal(
      resultPath(OUT, "v1.2/photo", "png"),
      path.join(OUT, "v1.2", "photo.png"),
    );
  });

  test("any case of the old extension is replaced", () => {
    assert.equal(resultPath(OUT, "A.JPG", "png"), path.join(OUT, "A.png"));
  });

  test("an input already named like the output still maps to that format", () => {
    assert.equal(resultPath(OUT, "a.png", "png"), path.join(OUT, "a.png"));
  });

  test("names with spaces and non-ASCII characters are preserved", () => {
    assert.equal(
      resultPath(OUT, "Café au lait/Ünï cödé 1.JPG", "png"),
      path.join(OUT, "Café au lait", "Ünï cödé 1.png"),
    );
  });

  test("adds no suffix to the file name", () => {
    assert.equal(path.basename(resultPath(OUT, "shot.jpg", "png")), "shot.png");
  });
});

describe("resultPath folders", () => {
  test("keeps subfolders under the output folder", () => {
    assert.equal(
      resultPath(OUT, "Trip/sub/a.jpg", "png"),
      path.join(OUT, "Trip", "sub", "a.png"),
    );
  });

  test("the result is always inside the output folder", () => {
    const result = resultPath(OUT, "Trip/sub/a.jpg", "png");
    assert.ok(result.startsWith(`${OUT}${path.sep}`));
    assert.equal(path.relative(OUT, result).startsWith(".."), false);
  });

  test("returns an absolute path when the output folder is absolute", () => {
    assert.ok(path.isAbsolute(resultPath(OUT, "a.jpg", "png")));
  });
});

describe("resultPath unsafe relative paths", () => {
  const unsafe = [
    "",
    ".",
    "..",
    "../a.jpg",
    "a/../b.jpg",
    "a/..",
    "a/./b.jpg",
    "./a.jpg",
    "a//b.jpg",
    "/a.jpg",
    "a/",
    "Trip/../../etc/passwd",
  ];

  for (const relative of unsafe) {
    test(`rejects ${JSON.stringify(relative)}`, () => {
      assert.throws(
        () => resultPath(OUT, relative, "png"),
        (error) =>
          error instanceof Error &&
          error.message === `Unsafe relative path ${JSON.stringify(relative)}`,
      );
    });
  }

  test("dots inside a segment are fine", () => {
    assert.equal(
      resultPath(OUT, "..a/b..jpg", "png"),
      path.join(OUT, "..a", "b..png"),
    );
    assert.equal(resultPath(OUT, "a...jpg", "png"), path.join(OUT, "a...png"));
  });
});
