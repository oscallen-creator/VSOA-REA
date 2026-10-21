import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { classifyError } from "../src/main/engineErrors.js";
import { ModelDownloadError } from "../src/engine/modelStore.js";

const NOT_WRITABLE =
  "Output folder is not writable. Please change output folder.";

const fsError = (code, stage, message = `${code}: failure`) =>
  Object.assign(new Error(message), { code, stage });

describe("classifyError model download", () => {
  test("a real ModelDownloadError is fatal model_unavailable", () => {
    const error = new ModelDownloadError("network", "connection reset");
    assert.deepEqual(classifyError(error), {
      code: "model_unavailable",
      fatal: true,
      message:
        "Could not download the background-removal model (connection reset). Check your internet connection and press Start again.",
    });
  });

  test("any error named ModelDownloadError is matched by name", () => {
    const error = Object.assign(new Error("offline"), {
      name: "ModelDownloadError",
    });
    const result = classifyError(error);
    assert.equal(result.code, "model_unavailable");
    assert.equal(result.fatal, true);
    assert.match(result.message, /\(offline\)/);
  });

  test("a plain object with that name is matched too", () => {
    const result = classifyError({
      name: "ModelDownloadError",
      message: "http 503",
    });
    assert.equal(result.code, "model_unavailable");
    assert.match(result.message, /\(http 503\)/);
  });

  test("the model rule wins over a write-stage code on the same error", () => {
    const error = Object.assign(new ModelDownloadError("aborted", "stopped"), {
      stage: "write",
      code: "EACCES",
    });
    assert.equal(classifyError(error).code, "model_unavailable");
  });
});

describe("classifyError write stage", () => {
  for (const code of ["EACCES", "EPERM", "EROFS"]) {
    test(`${code} while writing is a fatal unwritable output folder`, () => {
      assert.deepEqual(classifyError(fsError(code, "write")), {
        code: "output_dir_not_writable",
        fatal: true,
        message: NOT_WRITABLE,
      });
    });
  }

  test("ENOSPC while writing is a fatal full disk", () => {
    assert.deepEqual(classifyError(fsError("ENOSPC", "write")), {
      code: "disk_full",
      fatal: true,
      message: "The disk is full.",
    });
  });

  test("the unwritable message ignores the original error text", () => {
    const result = classifyError(
      fsError("EACCES", "write", "EACCES: permission denied, open '/secret'"),
    );
    assert.equal(result.message, NOT_WRITABLE);
  });

  test("other write-stage codes are not fatal and keep their code", () => {
    for (const code of ["EBUSY", "ENOENT", "EEXIST", "EIO"]) {
      const result = classifyError(fsError(code, "write", `${code} boom`));
      assert.deepEqual(result, { code, fatal: false, message: `${code} boom` });
    }
  });
});

describe("classifyError outside the write stage", () => {
  for (const stage of [undefined, "read", "decode", "segment", "compose"]) {
    test(`EACCES at stage ${String(stage)} is not fatal`, () => {
      const result = classifyError(fsError("EACCES", stage, "cannot open"));
      assert.deepEqual(result, {
        code: "EACCES",
        fatal: false,
        message: "cannot open",
      });
    });
  }

  test("EPERM, EROFS and ENOSPC without a write stage are not fatal", () => {
    for (const code of ["EPERM", "EROFS", "ENOSPC"]) {
      const result = classifyError(fsError(code, "read"));
      assert.equal(result.fatal, false, code);
      assert.equal(result.code, code);
    }
  });
});

describe("classifyError image problems", () => {
  test("unknown_foreground keeps its message and is not fatal", () => {
    const error = Object.assign(new Error("Could not find the subject"), {
      code: "unknown_foreground",
    });
    assert.deepEqual(classifyError(error), {
      code: "unknown_foreground",
      fatal: false,
      message: "Could not find the subject",
    });
  });

  test("unknown_foreground wins over image-format wording in its message", () => {
    const error = Object.assign(new Error("corrupt mask"), {
      code: "unknown_foreground",
    });
    assert.equal(classifyError(error).code, "unknown_foreground");
    assert.equal(classifyError(error).message, "corrupt mask");
  });

  test("an unsupported image format becomes load_image_error", () => {
    const error = new Error("Input file contains unsupported image format");
    assert.deepEqual(classifyError(error), {
      code: "load_image_error",
      fatal: false,
      message:
        "Could not read this image: Input file contains unsupported image format",
    });
  });

  test("corrupt and truncated images become load_image_error", () => {
    for (const message of [
      "VipsJpeg: Premature end of JPEG file",
      "PNG file is corrupt",
      "Input buffer has corrupt header",
      "UNSUPPORTED IMAGE FORMAT",
    ]) {
      const result = classifyError(new Error(message));
      assert.equal(result.code, "load_image_error", message);
      assert.equal(result.fatal, false, message);
      assert.equal(result.message, `Could not read this image: ${message}`);
    }
  });

  test("an image error replaces any original code", () => {
    const error = Object.assign(new Error("tiff is corrupt"), { code: "E_X" });
    assert.equal(classifyError(error).code, "load_image_error");
  });

  test("a write-stage permission error beats image-format wording", () => {
    const error = fsError("EACCES", "write", "corrupt output");
    assert.equal(classifyError(error).code, "output_dir_not_writable");
  });
});

describe("classifyError fallbacks", () => {
  test("keeps the error's own code and message", () => {
    const error = Object.assign(new Error("engine said no"), { code: "E_FOO" });
    assert.deepEqual(classifyError(error), {
      code: "E_FOO",
      fatal: false,
      message: "engine said no",
    });
  });

  test("falls back to process_image_error without a code", () => {
    assert.deepEqual(classifyError(new Error("out of memory")), {
      code: "process_image_error",
      fatal: false,
      message: "out of memory",
    });
  });

  test("never marks an unknown error fatal", () => {
    for (const error of [
      new Error("x"),
      new TypeError("y"),
      { message: "z" },
    ]) {
      assert.equal(classifyError(error).fatal, false);
    }
  });

  test("non-Error values are stringified", () => {
    assert.deepEqual(classifyError("plain text"), {
      code: "process_image_error",
      fatal: false,
      message: "plain text",
    });
    assert.equal(classifyError(undefined).message, "undefined");
    assert.equal(classifyError(null).message, "null");
    assert.equal(classifyError(42).message, "42");
    assert.equal(classifyError(null).code, "process_image_error");
  });

  test("always returns exactly code, fatal and message", () => {
    const inputs = [
      new ModelDownloadError("network", "x"),
      fsError("EACCES", "write"),
      fsError("ENOSPC", "write"),
      new Error("unsupported image format"),
      new Error("other"),
      undefined,
    ];
    for (const input of inputs) {
      assert.deepEqual(Object.keys(classifyError(input)).sort(), [
        "code",
        "fatal",
        "message",
      ]);
    }
  });

  test("fatal is a real boolean, as the queue checks it strictly", () => {
    // The queue treats `error.fatal === true` as stopping the whole run, so the
    // classifier must emit a real boolean rather than a truthy value.
    for (const error of [
      fsError("EROFS", "write"),
      fsError("ENOSPC", "write"),
    ]) {
      assert.strictEqual(classifyError(error).fatal, true);
    }
    assert.strictEqual(classifyError(new Error("x")).fatal, false);
  });
});
