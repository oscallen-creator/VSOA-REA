import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  OptionError,
  parseColor,
  parseLength,
  parseMargin,
  parseOptions,
  parsePosition,
  parseRoi,
  parseScale,
} from "../src/engine/options.js";

const px = (value) => ({ value, unit: "px" });
const pct = (value) => ({ value, unit: "%" });
const rgb = (r, g, b, alpha = 1) => ({ r, g, b, alpha });

const DEFAULTS = {
  size: "auto",
  format: "auto",
  channels: "rgba",
  type: "auto",
  bgColor: null,
  bgImage: null,
  crop: false,
  cropMargin: { top: px(0), right: px(0), bottom: px(0), left: px(0) },
  scale: null,
  position: null,
  roi: null,
};

// Asserts an OptionError naming `parameter` and (optionally) quoting the bad value.
const assertInvalid = (run, parameter, badValue) => {
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

const assertOptionRejected = (raw, parameter, badValue) =>
  assertInvalid(() => parseOptions(raw), parameter, badValue);

describe("OptionError", () => {
  test("is an Error with a stable code and the offending parameter", () => {
    const error = new OptionError("crop_margin", "nope");
    assert.ok(error instanceof Error);
    assert.equal(error.name, "OptionError");
    assert.equal(error.code, "invalid_option");
    assert.equal(error.parameter, "crop_margin");
    assert.equal(error.message, "nope");
  });

  test("reports the snake_case parameter even for camelCase input", () => {
    assertOptionRejected({ cropMargin: "-1" }, "crop_margin", '"-1"');
    assertOptionRejected({ bgColor: "banana" }, "bg_color", '"banana"');
    assertOptionRejected({ bgImage: "path.png" }, "bg_image", '"path.png"');
  });
});

describe("parseOptions defaults and shape", () => {
  test("returns the documented defaults with no input", () => {
    assert.deepEqual(parseOptions(), DEFAULTS);
    assert.deepEqual(parseOptions({}), DEFAULTS);
    assert.deepEqual(parseOptions(undefined), DEFAULTS);
    assert.deepEqual(parseOptions(null), DEFAULTS);
  });

  test("exposes exactly the contract's field names", () => {
    assert.deepEqual(Object.keys(parseOptions()).sort(), [
      "bgColor",
      "bgImage",
      "channels",
      "crop",
      "cropMargin",
      "format",
      "position",
      "roi",
      "scale",
      "size",
      "type",
    ]);
  });

  test("treats undefined and null for every key as the default", () => {
    const keys = [
      "size",
      "format",
      "channels",
      "type",
      "bg_color",
      "bg_image",
      "crop",
      "crop_margin",
      "scale",
      "position",
      "roi",
    ];
    assert.deepEqual(
      parseOptions(Object.fromEntries(keys.map((key) => [key, undefined]))),
      DEFAULTS,
    );
    assert.deepEqual(
      parseOptions(Object.fromEntries(keys.map((key) => [key, null]))),
      DEFAULTS,
    );
  });

  test("returns a deeply frozen object", () => {
    const options = parseOptions({
      bg_color: "red",
      crop_margin: "1 2 3 4",
      scale: "50%",
      roi: "0 0 10 10",
    });
    assert.ok(Object.isFrozen(options));
    assert.ok(Object.isFrozen(options.bgColor));
    assert.ok(Object.isFrozen(options.cropMargin));
    assert.ok(Object.isFrozen(options.cropMargin.top));
    assert.ok(Object.isFrozen(options.position));
    assert.ok(Object.isFrozen(options.roi));
    assert.ok(Object.isFrozen(options.roi[0]));
    assert.throws(() => {
      options.size = "full";
    }, TypeError);
    assert.throws(() => {
      options.cropMargin.top.value = 9;
    }, TypeError);
  });

  test("returns fresh nested objects on each call", () => {
    const first = parseOptions();
    const second = parseOptions();
    assert.notEqual(first.cropMargin, second.cropMargin);
    assert.notEqual(first.cropMargin.top, first.cropMargin.right);
  });

  test("does not mutate the caller's input", () => {
    const raw = Object.freeze({
      bgColor: "RED",
      crop_margin: " 5 ",
      crop: "1",
    });
    parseOptions(raw);
    assert.deepEqual(raw, { bgColor: "RED", crop_margin: " 5 ", crop: "1" });
  });

  test("accepts null-prototype objects such as querystring.parse results", () => {
    const raw = Object.assign(Object.create(null), { size: "full", crop: "1" });
    const options = parseOptions(raw);
    assert.equal(options.size, "full");
    assert.equal(options.crop, true);
  });

  test("rejects input that is not an object of options", () => {
    assertOptionRejected("size=full", "options", '"size=full"');
    assertOptionRejected(["size"], "options", "an array");
    assertOptionRejected(42, "options", "42");
  });
});

describe("parseOptions keys", () => {
  test("accepts camelCase and snake_case spellings interchangeably", () => {
    const pairs = [
      ["bgColor", "bg_color", "blue"],
      ["cropMargin", "crop_margin", "4 8"],
      ["bgImage", "bg_image", Buffer.from([1, 2, 3])],
      ["size", "size", "full"],
      ["format", "format", "webp"],
      ["channels", "channels", "alpha"],
      ["type", "type", "person"],
      ["crop", "crop", "true"],
      ["scale", "scale", "40%"],
      ["position", "position", "10% 20%"],
      ["roi", "roi", "1 2 3 4"],
    ];
    for (const [camel, snake, value] of pairs) {
      assert.deepEqual(
        parseOptions({ [camel]: value }),
        parseOptions({ [snake]: value }),
        `${camel} vs ${snake}`,
      );
    }
  });

  test("throws on an unknown key, naming it", () => {
    assertOptionRejected({ colour: "red" }, "colour", '"colour"');
    assertOptionRejected({ bg_colour: "red" }, "bg_colour", '"bg_colour"');
    assertOptionRejected({ SIZE: "full" }, "SIZE", '"SIZE"');
  });

  test("reports an unknown key exactly as it was sent", () => {
    assertOptionRejected({ fooBar: 1 }, "fooBar", '"fooBar"');
  });

  test("accepts only lowerCamelCase or snake_case spellings", () => {
    for (const key of ["BgColor", "bg_Color", "BG_COLOR", "Bg_color"]) {
      assertOptionRejected({ [key]: "red" }, key, JSON.stringify(key));
    }
  });

  test("throws on an unknown key even when its value is unset", () => {
    assertOptionRejected({ nope: undefined }, "nope");
    assertOptionRejected({ nope: null }, "nope");
  });

  test("does not mistake inherited object keys for options", () => {
    assertOptionRejected({ constructor: "x" }, "constructor");
    assertOptionRejected(JSON.parse('{"__proto__": 1}'), "__proto__");
  });

  test("throws when both spellings of one key are given", () => {
    assertOptionRejected({ bgColor: "red", bg_color: "blue" }, "bg_color");
    assertOptionRejected({ cropMargin: "1", crop_margin: "2" }, "crop_margin");
  });

  test("allows one spelling to be unset while the other is given", () => {
    const options = parseOptions({ bgColor: undefined, bg_color: "red" });
    assert.deepEqual(options.bgColor, rgb(255, 0, 0));
  });
});

describe("size", () => {
  test("accepts the three canonical values", () => {
    for (const size of ["preview", "full", "auto"]) {
      assert.equal(parseOptions({ size }).size, size);
    }
  });

  test("maps legacy aliases", () => {
    const aliases = {
      small: "preview",
      regular: "preview",
      medium: "full",
      hd: "full",
      "4k": "full",
    };
    for (const [alias, expected] of Object.entries(aliases)) {
      assert.equal(parseOptions({ size: alias }).size, expected, alias);
    }
  });

  test("is case-insensitive and trims whitespace", () => {
    assert.equal(parseOptions({ size: "FULL" }).size, "full");
    assert.equal(parseOptions({ size: "  4K " }).size, "full");
    assert.equal(parseOptions({ size: "Preview" }).size, "preview");
  });

  test("rejects unknown and non-string values", () => {
    assertOptionRejected({ size: "huge" }, "size", '"huge"');
    assertOptionRejected({ size: "" }, "size", '""');
    assertOptionRejected({ size: 4 }, "size", "4");
    assertOptionRejected({ size: "toString" }, "size", '"toString"');
  });
});

describe("format", () => {
  test("accepts every canonical format", () => {
    for (const format of ["auto", "png", "jpg", "webp", "zip"]) {
      assert.equal(parseOptions({ format }).format, format);
    }
  });

  test("accepts jpeg as jpg", () => {
    assert.equal(parseOptions({ format: "jpeg" }).format, "jpg");
    assert.equal(parseOptions({ format: "JPEG" }).format, "jpg");
  });

  test("is case-insensitive", () => {
    assert.equal(parseOptions({ format: "PNG" }).format, "png");
    assert.equal(parseOptions({ format: " WebP " }).format, "webp");
  });

  test("rejects unsupported formats", () => {
    assertOptionRejected({ format: "gif" }, "format", '"gif"');
    assertOptionRejected({ format: "" }, "format", '""');
    assertOptionRejected({ format: true }, "format", "true");
  });
});

describe("channels", () => {
  test("accepts rgba and alpha, case-insensitively", () => {
    assert.equal(parseOptions({ channels: "rgba" }).channels, "rgba");
    assert.equal(parseOptions({ channels: "alpha" }).channels, "alpha");
    assert.equal(parseOptions({ channels: "ALPHA" }).channels, "alpha");
  });

  test("rejects anything else", () => {
    assertOptionRejected({ channels: "rgb" }, "channels", '"rgb"');
    assertOptionRejected({ channels: 1 }, "channels", "1");
  });
});

describe("type", () => {
  test("accepts auto, person and product", () => {
    for (const type of ["auto", "person", "product"]) {
      assert.equal(parseOptions({ type }).type, type);
    }
    assert.equal(parseOptions({ type: "PERSON" }).type, "person");
  });

  test("maps remove.bg types without a local model to auto", () => {
    for (const type of ["car", "animal", "graphic", "transportation"]) {
      assert.equal(parseOptions({ type }).type, "auto", type);
    }
  });

  test("rejects unknown types", () => {
    assertOptionRejected({ type: "building" }, "type", '"building"');
  });
});

describe("parseColor", () => {
  test("parses 6-digit hex with and without #", () => {
    assert.deepEqual(parseColor("#81d4fa"), rgb(0x81, 0xd4, 0xfa));
    assert.deepEqual(parseColor("81d4fa"), rgb(0x81, 0xd4, 0xfa));
    assert.deepEqual(parseColor("#000000"), rgb(0, 0, 0));
    assert.deepEqual(parseColor("ffffff"), rgb(255, 255, 255));
  });

  test("expands 3-digit hex by doubling each digit", () => {
    assert.deepEqual(parseColor("#fff"), rgb(255, 255, 255));
    assert.deepEqual(parseColor("f80"), rgb(0xff, 0x88, 0x00));
    assert.deepEqual(parseColor("#123"), rgb(0x11, 0x22, 0x33));
  });

  test("reads the alpha of 4-digit hex", () => {
    assert.deepEqual(parseColor("#f808"), rgb(0xff, 0x88, 0x00, 0x88 / 255));
    assert.deepEqual(parseColor("0000"), rgb(0, 0, 0, 0));
    assert.deepEqual(parseColor("#fffF"), rgb(255, 255, 255, 1));
  });

  test("reads the alpha of 8-digit hex as a 0..1 fraction", () => {
    assert.deepEqual(parseColor("81d4fa77"), rgb(0x81, 0xd4, 0xfa, 0x77 / 255));
    assert.deepEqual(
      parseColor("#81d4fa77"),
      rgb(0x81, 0xd4, 0xfa, 0x77 / 255),
    );
    assert.deepEqual(parseColor("#ff000000"), rgb(255, 0, 0, 0));
    assert.deepEqual(parseColor("#ff0000ff"), rgb(255, 0, 0, 1));
    assert.ok(parseColor("81d4fa77").alpha > 0.46);
    assert.ok(parseColor("81d4fa77").alpha < 0.47);
  });

  test("is case-insensitive for hex digits", () => {
    assert.deepEqual(parseColor("#81D4FA"), rgb(0x81, 0xd4, 0xfa));
    assert.deepEqual(parseColor("ABC"), rgb(0xaa, 0xbb, 0xcc));
    assert.deepEqual(parseColor("81D4FA77"), parseColor("81d4fa77"));
  });

  test("parses the named colors", () => {
    const named = {
      black: rgb(0, 0, 0),
      white: rgb(255, 255, 255),
      red: rgb(255, 0, 0),
      green: rgb(0, 128, 0),
      blue: rgb(0, 0, 255),
      yellow: rgb(255, 255, 0),
      gray: rgb(128, 128, 128),
      grey: rgb(128, 128, 128),
      orange: rgb(255, 165, 0),
      purple: rgb(128, 0, 128),
      pink: rgb(255, 192, 203),
      transparent: rgb(0, 0, 0, 0),
    };
    for (const [name, expected] of Object.entries(named)) {
      assert.deepEqual(parseColor(name), expected, name);
    }
  });

  test("is case-insensitive for names and trims whitespace", () => {
    assert.deepEqual(parseColor("RED"), rgb(255, 0, 0));
    assert.deepEqual(parseColor("Green"), rgb(0, 128, 0));
    assert.deepEqual(parseColor("  Transparent "), rgb(0, 0, 0, 0));
    assert.deepEqual(parseColor(" #FFF "), rgb(255, 255, 255));
  });

  test("treats an empty or unset value as no color", () => {
    assert.equal(parseColor(""), null);
    assert.equal(parseColor("   "), null);
    assert.equal(parseColor(undefined), null);
    assert.equal(parseColor(null), null);
  });

  test("rejects malformed values, naming the value", () => {
    const bad = [
      "#12",
      "#12345",
      "#1234567",
      "#123456789",
      "ggg",
      "#gggggg",
      "notacolor",
      "# fff",
      "ff ff ff",
      "##fff",
      "#red",
      "rgb(1,2,3)",
    ];
    for (const value of bad) {
      assertInvalid(() => parseColor(value), "bg_color", JSON.stringify(value));
    }
  });

  test("rejects non-string values", () => {
    assertInvalid(() => parseColor(0xff0000), "bg_color", "16711680");
    assertInvalid(() => parseColor({ r: 1 }), "bg_color", "an object");
    assertInvalid(() => parseColor(true), "bg_color", "true");
  });

  test("is wired to bg_color / bgColor in parseOptions", () => {
    assert.deepEqual(
      parseOptions({ bg_color: "#fff" }).bgColor,
      rgb(255, 255, 255),
    );
    assert.deepEqual(parseOptions({ bgColor: "Blue" }).bgColor, rgb(0, 0, 255));
    assert.equal(parseOptions({ bg_color: "" }).bgColor, null);
    assertOptionRejected({ bg_color: "banana" }, "bg_color", '"banana"');
  });
});

describe("bg_image", () => {
  test("keeps a Buffer as the same instance, undecoded", () => {
    const image = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const options = parseOptions({ bg_image: image });
    assert.equal(options.bgImage, image);
    assert.deepEqual(options.bgImage, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  });

  test("converts a Uint8Array to a Buffer over the same bytes", () => {
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const { bgImage } = parseOptions({ bgImage: bytes });
    assert.ok(Buffer.isBuffer(bgImage));
    assert.deepEqual(bgImage, Buffer.from([1, 2, 3, 4]));
    bytes[0] = 9;
    assert.equal(bgImage[0], 9, "a view over the caller's bytes, not a copy");
  });

  test("respects the byte offset and length of a Uint8Array view", () => {
    const backing = new Uint8Array([0xff, 1, 2, 3, 0xff]);
    const { bgImage } = parseOptions({ bg_image: backing.subarray(1, 4) });
    assert.deepEqual(bgImage, Buffer.from([1, 2, 3]));
  });

  test("leaves the Buffer unfrozen so it stays usable", () => {
    const { bgImage } = parseOptions({ bg_image: Buffer.from([1, 2]) });
    assert.ok(!Object.isFrozen(bgImage));
    assert.ok(Object.isFrozen(parseOptions({ bg_image: bgImage })));
  });

  test("rejects anything that is not a Buffer or Uint8Array", () => {
    assertOptionRejected(
      { bg_image: "background.png" },
      "bg_image",
      '"background.png"',
    );
    assertOptionRejected({ bg_image: 5 }, "bg_image", "5");
    assertOptionRejected({ bg_image: [1, 2, 3] }, "bg_image", "an array");
    assertOptionRejected({ bg_image: {} }, "bg_image", "an object");
    assertOptionRejected({ bg_image: new Uint16Array(2) }, "bg_image");
    assertOptionRejected({ bg_image: new ArrayBuffer(4) }, "bg_image");
  });
});

describe("bg_color and bg_image together", () => {
  test("throws because remove.bg allows only one bg_ parameter", () => {
    assertOptionRejected(
      { bg_color: "red", bg_image: Buffer.from([1]) },
      "bg_color",
      '"red"',
    );
    assertOptionRejected(
      { bgColor: "#fff", bgImage: new Uint8Array([1]) },
      "bg_color",
      '"#fff"',
    );
  });

  test("names both parameters in the message", () => {
    assert.throws(
      () => parseOptions({ bg_color: "red", bg_image: Buffer.from([1]) }),
      /bg_color.*bg_image/,
    );
  });

  test("an empty bg_color does not conflict with bg_image", () => {
    const image = Buffer.from([1]);
    const options = parseOptions({ bg_color: "", bg_image: image });
    assert.equal(options.bgColor, null);
    assert.equal(options.bgImage, image);
  });

  test("null or undefined for one side does not conflict", () => {
    assert.ok(
      parseOptions({ bg_color: null, bg_image: Buffer.from([1]) }).bgImage,
    );
    assert.ok(parseOptions({ bg_color: "red", bg_image: undefined }).bgColor);
  });
});

describe("crop", () => {
  test("accepts booleans", () => {
    assert.equal(parseOptions({ crop: true }).crop, true);
    assert.equal(parseOptions({ crop: false }).crop, false);
  });

  test("accepts true/false/1/0 strings, case-insensitively", () => {
    for (const text of ["true", "TRUE", "True", "1", " true "]) {
      assert.equal(parseOptions({ crop: text }).crop, true, text);
    }
    for (const text of ["false", "FALSE", "False", "0", " 0 "]) {
      assert.equal(parseOptions({ crop: text }).crop, false, text);
    }
  });

  test("rejects other values", () => {
    for (const bad of ["yes", "no", "on", "", "2", "truthy"]) {
      assertOptionRejected({ crop: bad }, "crop", JSON.stringify(bad));
    }
    assertOptionRejected({ crop: 1 }, "crop", "1");
    assertOptionRejected({ crop: {} }, "crop", "an object");
  });
});

describe("parseLength", () => {
  test("parses px, percent and bare numbers", () => {
    assert.deepEqual(parseLength("10px"), px(10));
    assert.deepEqual(parseLength("25%"), pct(25));
    assert.deepEqual(parseLength("7"), px(7));
    assert.deepEqual(parseLength("0"), px(0));
  });

  test("parses decimals", () => {
    assert.deepEqual(parseLength("2.5px"), px(2.5));
    assert.deepEqual(parseLength(".5%"), pct(0.5));
    assert.deepEqual(parseLength("0.25"), px(0.25));
  });

  test("treats a number as px", () => {
    assert.deepEqual(parseLength(12), px(12));
    assert.deepEqual(parseLength(0.5), px(0.5));
  });

  test("is case-insensitive for the unit and trims whitespace", () => {
    assert.deepEqual(parseLength(" 10PX "), px(10));
  });

  test("never returns negative zero", () => {
    assert.ok(Object.is(parseLength(-0).value, 0));
    assert.ok(Object.is(parseLength("-0").value, 0));
  });

  test("rejects negative values", () => {
    assertInvalid(
      () => parseLength("-1px", "crop_margin"),
      "crop_margin",
      '"-1px"',
    );
    assertInvalid(() => parseLength(-5, "crop_margin"), "crop_margin", "-5");
    assertInvalid(() => parseLength("-0.5%", "roi"), "roi", '"-0.5%"');
  });

  test("rejects malformed and non-finite values", () => {
    const bad = [
      "",
      "px",
      "10 px",
      "10em",
      "1e3",
      "1,5",
      "--1",
      "+5",
      "abc",
      "5pxx",
    ];
    for (const value of bad) {
      assertInvalid(
        () => parseLength(value, "roi"),
        "roi",
        JSON.stringify(value),
      );
    }
    assertInvalid(() => parseLength(Number.NaN, "roi"), "roi", "NaN");
    assertInvalid(() => parseLength(Infinity, "roi"), "roi", "Infinity");
    assertInvalid(() => parseLength(null, "roi"), "roi", "null");
    assertInvalid(() => parseLength({}, "roi"), "roi", "an object");
  });

  test("keeps values above 100% as given", () => {
    assert.deepEqual(parseLength("250%"), pct(250));
  });
});

describe("parseMargin", () => {
  const sides = (top, right, bottom, left) => ({ top, right, bottom, left });

  test("defaults to zero px on every side", () => {
    assert.deepEqual(parseMargin(undefined), sides(px(0), px(0), px(0), px(0)));
    assert.deepEqual(parseMargin(null), sides(px(0), px(0), px(0), px(0)));
  });

  test("one value applies to all sides", () => {
    assert.deepEqual(
      parseMargin("10px"),
      sides(px(10), px(10), px(10), px(10)),
    );
    assert.deepEqual(parseMargin("5%"), sides(pct(5), pct(5), pct(5), pct(5)));
  });

  test("two values are top/bottom then left/right", () => {
    assert.deepEqual(
      parseMargin("10px 20%"),
      sides(px(10), pct(20), px(10), pct(20)),
    );
    assert.deepEqual(parseMargin("1 2"), sides(px(1), px(2), px(1), px(2)));
  });

  test("four values are top, right, bottom, left", () => {
    assert.deepEqual(
      parseMargin("1px 2% 3px 4%"),
      sides(px(1), pct(2), px(3), pct(4)),
    );
    assert.deepEqual(parseMargin("1 2 3 4"), sides(px(1), px(2), px(3), px(4)));
  });

  test("bare numbers mean px, mixed with explicit units", () => {
    assert.deepEqual(
      parseMargin("8 10%"),
      sides(px(8), pct(10), px(8), pct(10)),
    );
    assert.deepEqual(parseMargin("0"), sides(px(0), px(0), px(0), px(0)));
  });

  test("a number (not a string) means px on all sides", () => {
    assert.deepEqual(parseMargin(12), sides(px(12), px(12), px(12), px(12)));
    assert.deepEqual(parseMargin(0), sides(px(0), px(0), px(0), px(0)));
  });

  test("trims and allows runs of whitespace between values", () => {
    assert.deepEqual(
      parseMargin("  1px \t  2px   3px\n4px "),
      sides(px(1), px(2), px(3), px(4)),
    );
  });

  test("keeps over-cap values as given; the compositor caps them", () => {
    assert.deepEqual(
      parseMargin("600px"),
      sides(px(600), px(600), px(600), px(600)),
    );
    assert.deepEqual(
      parseMargin("75%"),
      sides(pct(75), pct(75), pct(75), pct(75)),
    );
  });

  test("returns independent objects per side", () => {
    const margin = parseMargin("10px");
    margin.top.value = 99;
    assert.equal(margin.right.value, 10);
    assert.equal(margin.bottom.value, 10);
    assert.equal(margin.left.value, 10);
  });

  test("rejects negative values, in any position", () => {
    assertInvalid(() => parseMargin("-1px"), "crop_margin", '"-1px"');
    assertInvalid(() => parseMargin("1 -2"), "crop_margin", '"-2"');
    assertInvalid(() => parseMargin("1 2 3 -4%"), "crop_margin", '"-4%"');
    assertInvalid(() => parseMargin(-3), "crop_margin", "-3");
  });

  test("rejects 0, 3 and 5+ values", () => {
    for (const bad of ["", "   ", "1 2 3", "1 2 3 4 5", "1 2 3 4 5 6"]) {
      assertInvalid(() => parseMargin(bad), "crop_margin", JSON.stringify(bad));
    }
  });

  test("rejects malformed lengths and other types", () => {
    assertInvalid(() => parseMargin("abc"), "crop_margin", '"abc"');
    assertInvalid(() => parseMargin("10 px"), "crop_margin", '"px"');
    assertInvalid(() => parseMargin("1em"), "crop_margin", '"1em"');
    assertInvalid(() => parseMargin(Number.NaN), "crop_margin", "NaN");
    assertInvalid(() => parseMargin([1, 2]), "crop_margin", "an array");
    assertInvalid(() => parseMargin(true), "crop_margin", "true");
  });

  test("is wired to crop_margin / cropMargin in parseOptions", () => {
    assert.deepEqual(
      parseOptions({ crop_margin: "10px 20%" }).cropMargin,
      sides(px(10), pct(20), px(10), pct(20)),
    );
    assert.deepEqual(
      parseOptions({ cropMargin: 4 }).cropMargin,
      sides(px(4), px(4), px(4), px(4)),
    );
    assertOptionRejected({ crop_margin: "1 2 3" }, "crop_margin", '"1 2 3"');
  });
});

describe("parseScale", () => {
  test("original means no scaling", () => {
    assert.equal(parseScale("original"), null);
    assert.equal(parseScale("ORIGINAL"), null);
    assert.equal(parseScale("  Original "), null);
    assert.equal(parseScale(undefined), null);
    assert.equal(parseScale(null), null);
  });

  test("converts percentages to fractions", () => {
    assert.equal(parseScale("10%"), 0.1);
    assert.equal(parseScale("50%"), 0.5);
    assert.equal(parseScale("33%"), 0.33);
    assert.equal(parseScale("100%"), 1);
    assert.equal(parseScale("12.5%"), 0.125);
    assert.equal(parseScale(" 75% "), 0.75);
  });

  test("accepts a bare number from 10 to 100 as a percentage", () => {
    assert.equal(parseScale("10"), 0.1);
    assert.equal(parseScale("100"), 1);
    assert.equal(parseScale("40"), 0.4);
    assert.equal(parseScale(25), 0.25);
    assert.equal(parseScale(100), 1);
  });

  test("rejects values below 10% or above 100%", () => {
    for (const bad of [
      "9%",
      "9.99%",
      "0%",
      "101%",
      "100.1%",
      "1000%",
      "5",
      "150",
    ]) {
      assertInvalid(() => parseScale(bad), "scale", JSON.stringify(bad));
    }
    assertInvalid(() => parseScale(9), "scale", "9");
    assertInvalid(() => parseScale(101), "scale", "101");
    assertInvalid(() => parseScale(0.5), "scale", "0.5");
  });

  test("rejects malformed values", () => {
    for (const bad of ["", "abc", "50px", "-10%", "10 %", "%", "1e2", "50%%"]) {
      assertInvalid(() => parseScale(bad), "scale", JSON.stringify(bad));
    }
    assertInvalid(() => parseScale(Number.NaN), "scale", "NaN");
    assertInvalid(() => parseScale(true), "scale", "true");
    assertInvalid(() => parseScale({}), "scale", "an object");
  });

  test("is wired to scale in parseOptions", () => {
    assert.equal(parseOptions({ scale: "10%" }).scale, 0.1);
    assert.equal(parseOptions({ scale: "100%" }).scale, 1);
    assert.equal(parseOptions({ scale: "original" }).scale, null);
    assertOptionRejected({ scale: "9%" }, "scale", '"9%"');
    assertOptionRejected({ scale: "101%" }, "scale", '"101%"');
  });
});

describe("parsePosition", () => {
  test("original means no repositioning", () => {
    assert.equal(parsePosition("original"), null);
    assert.equal(parsePosition(" ORIGINAL "), null);
    assert.equal(parsePosition(undefined), null);
    assert.equal(parsePosition(null), null);
  });

  test("center is the middle of both axes", () => {
    assert.deepEqual(parsePosition("center"), { x: 0.5, y: 0.5 });
    assert.deepEqual(parsePosition("CENTER"), { x: 0.5, y: 0.5 });
  });

  test("one percentage sets both axes", () => {
    assert.deepEqual(parsePosition("50%"), { x: 0.5, y: 0.5 });
    assert.deepEqual(parsePosition("0%"), { x: 0, y: 0 });
    assert.deepEqual(parsePosition("100%"), { x: 1, y: 1 });
    assert.deepEqual(parsePosition("25%"), { x: 0.25, y: 0.25 });
  });

  test("two percentages are x then y", () => {
    assert.deepEqual(parsePosition("0% 100%"), { x: 0, y: 1 });
    assert.deepEqual(parsePosition("100% 0%"), { x: 1, y: 0 });
    assert.deepEqual(parsePosition("25% 75%"), { x: 0.25, y: 0.75 });
    assert.deepEqual(parsePosition("12.5% 87.5%"), { x: 0.125, y: 0.875 });
  });

  test("allows extra whitespace between and around values", () => {
    assert.deepEqual(parsePosition("  10%    20%  "), { x: 0.1, y: 0.2 });
    assert.deepEqual(parsePosition("10%\t20%"), { x: 0.1, y: 0.2 });
  });

  test("rejects percentages outside 0..100", () => {
    assertInvalid(() => parsePosition("101%"), "position", '"101%"');
    assertInvalid(
      () => parsePosition("50% 100.5%"),
      "position",
      '"50% 100.5%"',
    );
    assertInvalid(() => parsePosition("-1%"), "position");
    assertInvalid(() => parsePosition("0% -10%"), "position");
  });

  test("rejects bare numbers, other units and other words", () => {
    for (const bad of ["50", "50px", "left", "top left", "centre", "50% 50"]) {
      assertInvalid(() => parsePosition(bad), "position", JSON.stringify(bad));
    }
  });

  test("rejects the wrong number of values and non-strings", () => {
    for (const bad of ["", "   ", "10% 20% 30%", "0% 0% 0% 0%"]) {
      assertInvalid(() => parsePosition(bad), "position", JSON.stringify(bad));
    }
    assertInvalid(() => parsePosition(50), "position", "50");
    assertInvalid(() => parsePosition({ x: 1, y: 1 }), "position", "an object");
  });
});

describe("position default in parseOptions", () => {
  test("is null when neither scale nor position is given", () => {
    const options = parseOptions({});
    assert.equal(options.scale, null);
    assert.equal(options.position, null);
  });

  test("defaults to center when scale is set and position is not", () => {
    const options = parseOptions({ scale: "50%" });
    assert.equal(options.scale, 0.5);
    assert.deepEqual(options.position, { x: 0.5, y: 0.5 });
  });

  test("applies the center default for every valid scale", () => {
    for (const scale of ["10%", "100%", "40", 25]) {
      assert.deepEqual(parseOptions({ scale }).position, { x: 0.5, y: 0.5 });
    }
  });

  test("an explicit position wins over the implied center", () => {
    const options = parseOptions({ scale: "50%", position: "0% 100%" });
    assert.deepEqual(options.position, { x: 0, y: 1 });
  });

  test("explicit original keeps position null even with a scale", () => {
    const options = parseOptions({ scale: "50%", position: "original" });
    assert.equal(options.scale, 0.5);
    assert.equal(options.position, null);
  });

  test("scale original implies no position", () => {
    const options = parseOptions({ scale: "original" });
    assert.equal(options.scale, null);
    assert.equal(options.position, null);
  });

  test("null or undefined position still counts as not given", () => {
    assert.deepEqual(parseOptions({ scale: "50%", position: null }).position, {
      x: 0.5,
      y: 0.5,
    });
    assert.deepEqual(
      parseOptions({ scale: "50%", position: undefined }).position,
      { x: 0.5, y: 0.5 },
    );
  });

  test("a position without a scale is kept", () => {
    assert.deepEqual(parseOptions({ position: "center" }).position, {
      x: 0.5,
      y: 0.5,
    });
    assert.deepEqual(parseOptions({ position: "10% 90%" }).position, {
      x: 0.1,
      y: 0.9,
    });
    assert.equal(parseOptions({ position: "original" }).position, null);
  });

  test("an invalid position is still rejected when a scale is set", () => {
    assertOptionRejected(
      { scale: "50%", position: "150%" },
      "position",
      '"150%"',
    );
  });
});

describe("parseRoi", () => {
  test("is null when unset", () => {
    assert.equal(parseRoi(undefined), null);
    assert.equal(parseRoi(null), null);
  });

  test("parses four px lengths", () => {
    assert.deepEqual(parseRoi("10px 20px 300px 400px"), [
      px(10),
      px(20),
      px(300),
      px(400),
    ]);
  });

  test("treats bare numbers as px", () => {
    assert.deepEqual(parseRoi("0 0 100 50"), [px(0), px(0), px(100), px(50)]);
  });

  test("parses percentages", () => {
    assert.deepEqual(parseRoi("10% 20% 90% 80%"), [
      pct(10),
      pct(20),
      pct(90),
      pct(80),
    ]);
  });

  test("returns the whole-image percentages as given, not as null", () => {
    assert.deepEqual(parseRoi("0% 0% 100% 100%"), [
      pct(0),
      pct(0),
      pct(100),
      pct(100),
    ]);
  });

  test("allows different units across coordinates", () => {
    assert.deepEqual(parseRoi("10px 10% 200px 90%"), [
      px(10),
      pct(10),
      px(200),
      pct(90),
    ]);
  });

  test("does not compare coordinates whose units differ", () => {
    // Unknowable without the image size, so it is left for the compositor.
    assert.deepEqual(parseRoi("50% 0 10 100"), [
      pct(50),
      px(0),
      px(10),
      px(100),
    ]);
    assert.deepEqual(parseRoi("500 0% 10% 100%"), [
      px(500),
      pct(0),
      pct(10),
      pct(100),
    ]);
  });

  test("trims and allows runs of whitespace", () => {
    assert.deepEqual(parseRoi("  1   2\t3  4 "), [px(1), px(2), px(3), px(4)]);
  });

  test("accepts decimals", () => {
    assert.deepEqual(parseRoi("0.5 1.5 2.5 3.5"), [
      px(0.5),
      px(1.5),
      px(2.5),
      px(3.5),
    ]);
  });
});

describe("parseRoi rejections", () => {
  test("rejects anything but exactly four values", () => {
    for (const bad of ["", "  ", "1", "1 2 3", "1 2 3 4 5"]) {
      assertInvalid(() => parseRoi(bad), "roi", JSON.stringify(bad));
    }
  });

  test("rejects x2 <= x1 and y2 <= y1 within the same unit", () => {
    assertInvalid(() => parseRoi("100 0 50 100"), "roi", '"100 0 50 100"');
    assertInvalid(() => parseRoi("0 100 100 50"), "roi", '"0 100 100 50"');
    assertInvalid(() => parseRoi("10 0 10 100"), "roi", '"10 0 10 100"');
    assertInvalid(() => parseRoi("0 10 100 10"), "roi", '"0 10 100 10"');
    assertInvalid(
      () => parseRoi("60% 0% 40% 100%"),
      "roi",
      '"60% 0% 40% 100%"',
    );
    assertInvalid(
      () => parseRoi("0% 50% 100% 50%"),
      "roi",
      '"0% 50% 100% 50%"',
    );
  });

  test("rejects percentages above 100", () => {
    assertInvalid(
      () => parseRoi("0% 0% 101% 100%"),
      "roi",
      '"0% 0% 101% 100%"',
    );
    assertInvalid(() => parseRoi("0% 0% 100% 100.5%"), "roi");
    assertInvalid(() => parseRoi("0 0% 100 150%"), "roi");
  });

  test("rejects negatives and malformed lengths", () => {
    assertInvalid(() => parseRoi("-1 0 10 10"), "roi", '"-1"');
    assertInvalid(() => parseRoi("0 0 10 -10%"), "roi", '"-10%"');
    assertInvalid(() => parseRoi("a b c d"), "roi", '"a"');
    assertInvalid(() => parseRoi("0 0 10 10em"), "roi", '"10em"');
  });

  test("rejects non-string values", () => {
    assertInvalid(() => parseRoi([0, 0, 10, 10]), "roi", "an array");
    assertInvalid(() => parseRoi(5), "roi", "5");
    assertInvalid(() => parseRoi({}), "roi", "an object");
  });

  test("is wired to roi in parseOptions", () => {
    assert.deepEqual(parseOptions({ roi: "0 0 10% 10%" }).roi, [
      px(0),
      px(0),
      pct(10),
      pct(10),
    ]);
    assert.deepEqual(parseOptions({ roi: "0% 0% 100% 100%" }).roi, [
      pct(0),
      pct(0),
      pct(100),
      pct(100),
    ]);
    assertOptionRejected({ roi: "5 5 1 1" }, "roi", '"5 5 1 1"');
  });
});

describe("parseOptions with every option set", () => {
  test("combines all fields as a form submission would", () => {
    const options = parseOptions({
      size: "HD",
      format: "JPEG",
      channels: "Alpha",
      type: "car",
      bg_color: "#81D4FA77",
      crop: "true",
      crop_margin: "10px 5%",
      scale: "80%",
      position: "0% 100%",
      roi: "5% 5% 95% 95%",
    });
    assert.deepEqual(options, {
      size: "full",
      format: "jpg",
      channels: "alpha",
      type: "auto",
      bgColor: rgb(0x81, 0xd4, 0xfa, 0x77 / 255),
      bgImage: null,
      crop: true,
      cropMargin: {
        top: px(10),
        right: pct(5),
        bottom: px(10),
        left: pct(5),
      },
      scale: 0.8,
      position: { x: 0, y: 1 },
      roi: [pct(5), pct(5), pct(95), pct(95)],
    });
  });

  test("reports the first invalid option and does not return partial results", () => {
    assertOptionRejected({ size: "full", format: "gif" }, "format", '"gif"');
    assert.throws(
      () => parseOptions({ crop_margin: "1 2 3", scale: "5%" }),
      OptionError,
    );
  });
});
