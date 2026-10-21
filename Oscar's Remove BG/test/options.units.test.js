import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  parseLength,
  parseMargin,
  parseOptions,
  parsePosition,
  parseRoi,
  parseScale,
} from "../src/engine/options.js";
import {
  CENTER,
  assertAllInvalid,
  assertInvalid,
  assertOptionRejected,
  assertRows,
  pct,
  px,
  sides,
} from "./options.helpers.test.js";

describe("parseLength", () => {
  test("parses px, percent, decimals and numbers; units are case-insensitive", () => {
    assertRows(parseLength, [
      ["10px", px(10)],
      ["25%", pct(25)],
      ["7", px(7)],
      ["0", px(0)],
      ["2.5px", px(2.5)],
      [".5%", pct(0.5)],
      ["0.25", px(0.25)],
      [12, px(12)],
      [0.5, px(0.5)],
      [" 10PX ", px(10)],
      ["250%", pct(250)], // above 100% is kept as given
    ]);
    assert.ok(Object.is(parseLength(-0).value, 0), "never negative zero");
    assert.ok(Object.is(parseLength("-0").value, 0));
  });

  test("rejects negative, malformed and non-finite values", () => {
    assertAllInvalid(
      (value) => parseLength(value, "crop_margin"),
      "crop_margin",
      [
        ["-1px", "-0.5%", -5, "", "px", "10 px", "10em", "1e3", "1,5"],
        ["--1", "+5", "abc", "5pxx", Number.NaN, Infinity, null, {}],
      ].flat(),
    );
  });
});

describe("parseMargin", () => {
  const ZERO = sides(px(0), px(0), px(0), px(0));
  const all = (length) => sides(length, length, length, length);

  test("defaults to zero px; one value is all sides; a number is px", () => {
    assertRows(parseMargin, [
      [undefined, ZERO],
      [null, ZERO],
      ["0", ZERO],
      [0, ZERO],
      ["10px", all(px(10))],
      ["5%", all(pct(5))],
      [12, all(px(12))],
      // Over-cap values are kept as given; the compositor caps them.
      ["600px", all(px(600))],
      ["75%", all(pct(75))],
    ]);
  });

  test("two values are top/bottom then left/right", () => {
    assertRows(parseMargin, [
      ["10px 20%", sides(px(10), pct(20), px(10), pct(20))],
      ["1 2", sides(px(1), px(2), px(1), px(2))],
      ["8 10%", sides(px(8), pct(10), px(8), pct(10))],
    ]);
  });

  test("four values are top, right, bottom, left; whitespace is flexible", () => {
    const expected = sides(px(1), px(2), px(3), px(4));
    assertRows(parseMargin, [
      ["1px 2% 3px 4%", sides(px(1), pct(2), px(3), pct(4))],
      ["1 2 3 4", expected],
      ["  1px \t  2px   3px\n4px ", expected],
    ]);
  });

  test("returns independent objects per side", () => {
    const margin = parseMargin("10px");
    margin.top.value = 99;
    assert.equal(margin.right.value, 10);
    assert.equal(margin.bottom.value, 10);
    assert.equal(margin.left.value, 10);
  });

  test("rejects negatives, wrong counts, malformed lengths and other types", () => {
    assertAllInvalid(
      parseMargin,
      "crop_margin",
      [
        ["-1px", "1 -2", "1 2 3 -4%", -3],
        ["", "   ", "1 2 3", "1 2 3 4 5", "1 2 3 4 5 6"],
        ["abc", "10 px", "1em", Number.NaN, [1, 2], true],
      ].flat(),
      () => undefined, // the message quotes the bad token, checked below
    );
    assertInvalid(() => parseMargin("1 -2"), "crop_margin", '"-2"');
    assertInvalid(() => parseMargin("10 px"), "crop_margin", '"px"');
  });

  test("is wired to crop_margin / cropMargin in parseOptions", () => {
    assert.deepEqual(
      parseOptions({ crop_margin: "10px 20%" }).cropMargin,
      sides(px(10), pct(20), px(10), pct(20)),
    );
    assert.deepEqual(parseOptions({ cropMargin: 4 }).cropMargin, all(px(4)));
    assertOptionRejected({ crop_margin: "1 2 3" }, "crop_margin", '"1 2 3"');
  });
});

describe("parseScale", () => {
  test("original means no scaling", () => {
    const originals = ["original", "ORIGINAL", "  Original ", undefined, null];
    assertRows(
      parseScale,
      originals.map((value) => [value, null]),
    );
  });

  test("converts 10% to 100% to fractions; a bare number is a percent", () => {
    assertRows(parseScale, [
      ["10%", 0.1],
      ["50%", 0.5],
      ["33%", 0.33],
      ["100%", 1],
      ["12.5%", 0.125],
      [" 75% ", 0.75],
      ["10", 0.1],
      ["100", 1],
      ["40", 0.4],
      [25, 0.25],
      [100, 1],
    ]);
  });

  test("rejects values outside 10..100 and malformed values", () => {
    assertAllInvalid(
      parseScale,
      "scale",
      [
        ["9%", "9.99%", "0%", "101%", "100.1%", "1000%", "5", "150"],
        ["", "abc", "50px", "-10%", "10 %", "%", "1e2", "50%%"],
        [9, 101, 0.5, Number.NaN, true, {}],
      ].flat(),
    );
  });

  test("is wired to scale in parseOptions", () => {
    assert.equal(parseOptions({ scale: "10%" }).scale, 0.1);
    assert.equal(parseOptions({ scale: "original" }).scale, null);
    assertOptionRejected({ scale: "9%" }, "scale", '"9%"');
    assertOptionRejected({ scale: "101%" }, "scale", '"101%"');
  });
});

describe("parsePosition", () => {
  const at = (x, y) => ({ x, y });

  test("original is null, center is the middle, percentages are x then y", () => {
    assertRows(parsePosition, [
      ["original", null],
      [" ORIGINAL ", null],
      [undefined, null],
      [null, null],
      ["center", CENTER],
      ["CENTER", CENTER],
      // One percentage sets both axes.
      ["50%", CENTER],
      ["0%", at(0, 0)],
      ["100%", at(1, 1)],
      ["25%", at(0.25, 0.25)],
      ["0% 100%", at(0, 1)],
      ["100% 0%", at(1, 0)],
      ["25% 75%", at(0.25, 0.75)],
      ["12.5% 87.5%", at(0.125, 0.875)],
      ["  10%    20%  ", at(0.1, 0.2)],
      ["10%\t20%", at(0.1, 0.2)],
    ]);
  });

  test("rejects percentages outside 0..100, other units, words and counts", () => {
    assertAllInvalid(
      parsePosition,
      "position",
      [
        ["101%", "50% 100.5%", "-1%", "0% -10%"],
        ["50", "50px", "left", "top left", "centre", "50% 50"],
        ["", "   ", "10% 20% 30%", "0% 0% 0% 0%", 50, { x: 1, y: 1 }],
      ].flat(),
    );
  });

  test("defaults to center when only a scale is given", () => {
    const rows = [
      [{}, null, null],
      [{ scale: "50%" }, 0.5, CENTER],
      [{ scale: "original" }, null, null],
      [{ scale: "50%", position: null }, 0.5, CENTER],
      [{ scale: "50%", position: undefined }, 0.5, CENTER],
      // An explicit position wins, including an explicit "original".
      [{ scale: "50%", position: "0% 100%" }, 0.5, at(0, 1)],
      [{ scale: "50%", position: "original" }, 0.5, null],
      // A position without a scale is kept.
      [{ position: "center" }, null, CENTER],
      [{ position: "10% 90%" }, null, at(0.1, 0.9)],
      [{ position: "original" }, null, null],
      [{ scale: "10%" }, 0.1, CENTER],
      [{ scale: "100%" }, 1, CENTER],
      [{ scale: "40" }, 0.4, CENTER],
      [{ scale: 25 }, 0.25, CENTER],
    ];
    for (const [raw, scale, position] of rows) {
      const options = parseOptions(raw);
      assert.deepEqual(
        { scale: options.scale, position: options.position },
        { scale, position },
        JSON.stringify(raw),
      );
    }
    assertOptionRejected(
      { scale: "50%", position: "150%" },
      "position",
      '"150%"',
    );
  });
});

describe("parseRoi", () => {
  test("is null when unset", () => {
    assertRows(parseRoi, [
      [undefined, null],
      [null, null],
    ]);
  });

  test("parses four lengths, keeping units and values as given", () => {
    assertRows(parseRoi, [
      ["10px 20px 300px 400px", [px(10), px(20), px(300), px(400)]],
      ["0 0 100 50", [px(0), px(0), px(100), px(50)]],
      ["10% 20% 90% 80%", [pct(10), pct(20), pct(90), pct(80)]],
      // The whole image stays as percentages rather than becoming null.
      ["0% 0% 100% 100%", [pct(0), pct(0), pct(100), pct(100)]],
      ["10px 10% 200px 90%", [px(10), pct(10), px(200), pct(90)]],
      ["  1   2\t3  4 ", [px(1), px(2), px(3), px(4)]],
      ["0.5 1.5 2.5 3.5", [px(0.5), px(1.5), px(2.5), px(3.5)]],
      // Coordinates in different units are not compared; the compositor does.
      ["50% 0 10 100", [pct(50), px(0), px(10), px(100)]],
      ["500 0% 10% 100%", [px(500), pct(0), pct(10), pct(100)]],
    ]);
  });

  test("rejects the wrong count, inverted boxes, bad lengths and non-strings", () => {
    assertAllInvalid(
      parseRoi,
      "roi",
      [
        ["", "  ", "1", "1 2 3", "1 2 3 4 5"],
        ["100 0 50 100", "0 100 100 50", "10 0 10 100", "0 10 100 10"],
        ["60% 0% 40% 100%", "0% 50% 100% 50%"],
        ["0% 0% 101% 100%", "0% 0% 100% 100.5%", "0 0% 100 150%"],
        ["-1 0 10 10", "0 0 10 -10%", "a b c d", "0 0 10 10em"],
        [[0, 0, 10, 10], 5, {}],
      ].flat(),
      () => undefined, // some messages quote one token, checked below
    );
    assertInvalid(() => parseRoi("-1 0 10 10"), "roi", '"-1"');
    assertInvalid(() => parseRoi("a b c d"), "roi", '"a"');
    assertInvalid(() => parseRoi("100 0 50 100"), "roi", '"100 0 50 100"');
  });

  test("is wired to roi in parseOptions", () => {
    assert.deepEqual(parseOptions({ roi: "0 0 10% 10%" }).roi, [
      px(0),
      px(0),
      pct(10),
      pct(10),
    ]);
    assertOptionRejected({ roi: "5 5 1 1" }, "roi", '"5 5 1 1"');
  });
});
