// Shared fixtures and assertions for the options tests. It has no tests of its
// own; it is named *.test.js so the test glob and the file allow-list cover it.
import assert from "node:assert/strict";
import { OptionError, parseOptions } from "../src/engine/options.js";

export const px = (value) => ({ value, unit: "px" });
export const pct = (value) => ({ value, unit: "%" });
export const rgb = (r, g, b, alpha = 1) => ({ r, g, b, alpha });
export const sides = (top, right, bottom, left) => ({
  top,
  right,
  bottom,
  left,
});
export const CENTER = Object.freeze({ x: 0.5, y: 0.5 });

// How an invalid value is quoted in an error message.
export const shown = (value) => {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value !== "object" || value === null) return String(value);
  return Array.isArray(value) ? "an array" : "an object";
};

// Asserts an OptionError naming `parameter` and (optionally) quoting the bad value.
export const assertInvalid = (run, parameter, badValue) => {
  assert.throws(run, (error) => {
    assert.ok(error instanceof OptionError, `expected OptionError: ${error}`);
    assert.equal(error.code, "invalid_option");
    assert.equal(error.parameter, parameter);
    assert.ok(
      error.message.includes(parameter),
      `message names the parameter: ${error.message}`,
    );
    if (badValue !== undefined) {
      assert.ok(
        error.message.includes(badValue),
        `message quotes ${badValue}: ${error.message}`,
      );
    }
    return true;
  });
};

export const assertOptionRejected = (raw, parameter, badValue) =>
  assertInvalid(() => parseOptions(raw), parameter, badValue);

// Table helpers: [input, expected] rows, and inputs that must all be rejected.
// `quoted` says what the message must contain for an input (default: the input
// as shown); pass () => undefined where the message names one token of it.
export const assertRows = (parse, rows) => {
  for (const [input, expected] of rows) {
    assert.deepEqual(parse(input), expected, `input ${shown(input)}`);
  }
};
export const assertAllInvalid = (parse, parameter, inputs, quoted = shown) => {
  for (const input of inputs) {
    assertInvalid(() => parse(input), parameter, quoted(input));
  }
};
