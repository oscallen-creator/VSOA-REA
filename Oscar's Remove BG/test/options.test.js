import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  OptionError,
  parseColor,
  parseOptions,
} from "../src/engine/options.js";
import {
  assertAllInvalid,
  assertOptionRejected,
  assertRows,
  pct,
  px,
  rgb,
  sides,
  shown,
} from "./options.helpers.test.js";

const DEFAULTS = {
  size: "auto",
  format: "auto",
  channels: "rgba",
  type: "auto",
  bgColor: null,
  bgImage: null,
  crop: false,
  cropMargin: sides(px(0), px(0), px(0), px(0)),
  scale: null,
  position: null,
  roi: null,
  shadowType: "none",
  shadowOpacity: 0,
};

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
    assertOptionRejected({ shadowType: "x" }, "shadow_type", '"x"');
    assertOptionRejected({ shadowOpacity: "x" }, "shadow_opacity", '"x"');
  });
});

describe("parseOptions defaults and shape", () => {
  test("returns the documented defaults, and only those fields, with no input", () => {
    for (const raw of [undefined, null, {}]) {
      assert.deepEqual(parseOptions(raw), DEFAULTS);
    }
    assert.deepEqual(parseOptions(), DEFAULTS);
  });

  test("treats undefined and null for every key as the default", () => {
    const keys = [
      ["size", "format", "channels", "type", "bg_color", "bg_image"],
      ["crop", "crop_margin", "scale", "position", "roi"],
      ["shadow_type", "shadow_opacity"],
    ].flat();
    for (const unset of [undefined, null]) {
      const raw = Object.fromEntries(keys.map((key) => [key, unset]));
      assert.deepEqual(parseOptions(raw), DEFAULTS);
    }
  });

  test("returns a deeply frozen object with fresh nested objects", () => {
    const options = parseOptions({
      bg_color: "red",
      crop_margin: "1 2 3 4",
      scale: "50%",
      roi: "0 0 10 10",
    });
    for (const frozen of [
      options,
      options.bgColor,
      options.cropMargin,
      options.cropMargin.top,
      options.position,
      options.roi,
      options.roi[0],
    ]) {
      assert.ok(Object.isFrozen(frozen));
    }
    assert.throws(() => {
      options.size = "full";
    }, TypeError);
    assert.throws(() => {
      options.cropMargin.top.value = 9;
    }, TypeError);

    const first = parseOptions();
    assert.notEqual(first.cropMargin, parseOptions().cropMargin);
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
      ["shadowType", "shadow_type", "drop"],
      ["shadowOpacity", "shadow_opacity", "30"],
    ];
    for (const [camel, snake, value] of pairs) {
      assert.deepEqual(
        parseOptions({ [camel]: value }),
        parseOptions({ [snake]: value }),
        `${camel} vs ${snake}`,
      );
    }
  });

  test("throws on an unknown key, naming it exactly as sent", () => {
    // Only lowerCamelCase and snake_case spellings are accepted.
    const unknown = ["colour", "bg_colour", "SIZE", "fooBar", "BgColor"];
    for (const key of [...unknown, "bg_Color", "BG_COLOR", "Bg_color"]) {
      assertOptionRejected({ [key]: "red" }, key, JSON.stringify(key));
    }
    // Even when the value is unset, and never an inherited object key.
    assertOptionRejected({ nope: undefined }, "nope");
    assertOptionRejected({ nope: null }, "nope");
    assertOptionRejected({ constructor: "x" }, "constructor");
    assertOptionRejected(JSON.parse('{"__proto__": 1}'), "__proto__");
  });

  test("throws when both spellings of one key are given", () => {
    assertOptionRejected({ bgColor: "red", bg_color: "blue" }, "bg_color");
    assertOptionRejected({ cropMargin: "1", crop_margin: "2" }, "crop_margin");
    assertOptionRejected(
      { shadowType: "drop", shadow_type: "car" },
      "shadow_type",
    );
  });

  test("allows one spelling to be unset while the other is given", () => {
    const options = parseOptions({ bgColor: undefined, bg_color: "red" });
    assert.deepEqual(options.bgColor, rgb(255, 0, 0));
  });
});

describe("choice options", () => {
  const CHOICES = {
    size: {
      accepts: {
        preview: "preview",
        full: "full",
        auto: "auto",
        // Legacy aliases, any case, padded.
        small: "preview",
        regular: "preview",
        medium: "full",
        hd: "full",
        "4k": "full",
        FULL: "full",
        "  4K ": "full",
        Preview: "preview",
      },
      rejects: ["huge", "", 4, "toString"],
    },
    format: {
      accepts: {
        auto: "auto",
        png: "png",
        jpg: "jpg",
        webp: "webp",
        zip: "zip",
        jpeg: "jpg",
        JPEG: "jpg",
        PNG: "png",
        " WebP ": "webp",
      },
      rejects: ["gif", "", true],
    },
    channels: {
      accepts: { rgba: "rgba", alpha: "alpha", ALPHA: "alpha" },
      rejects: ["rgb", 1],
    },
    type: {
      accepts: {
        auto: "auto",
        person: "person",
        product: "product",
        PERSON: "person",
        // remove.bg types without a local model.
        car: "auto",
        animal: "auto",
        graphic: "auto",
        transportation: "auto",
      },
      rejects: ["building"],
    },
    shadow_type: {
      accepts: {
        none: "none",
        auto: "auto",
        car: "car",
        "3D": "3D",
        drop: "drop",
        "3d": "3D",
        DROP: "drop",
        " Car ": "car",
      },
      rejects: ["shadow", "3", "dropshadow", "", 3, true],
    },
  };
  const camel = (name) => name.replace(/_(\w)/g, (_, c) => c.toUpperCase());

  for (const [parameter, { accepts, rejects }] of Object.entries(CHOICES)) {
    test(`${parameter} maps accepted spellings and rejects the rest`, () => {
      for (const [input, expected] of Object.entries(accepts)) {
        const options = parseOptions({ [parameter]: input });
        assert.equal(options[camel(parameter)], expected, `"${input}"`);
      }
      assertAllInvalid(
        (value) => parseOptions({ [parameter]: value }),
        parameter,
        rejects,
      );
    });
  }
});

describe("parseColor", () => {
  const COLORS = [
    ["#81d4fa", rgb(0x81, 0xd4, 0xfa)],
    ["81d4fa", rgb(0x81, 0xd4, 0xfa)],
    ["#000000", rgb(0, 0, 0)],
    ["ffffff", rgb(255, 255, 255)],
    // 3 digits double each digit; 4 and 8 digits carry alpha as a 0..1 fraction.
    ["#fff", rgb(255, 255, 255)],
    ["f80", rgb(0xff, 0x88, 0)],
    ["#123", rgb(0x11, 0x22, 0x33)],
    ["0000", rgb(0, 0, 0, 0)],
    ["#f808", rgb(0xff, 0x88, 0, 0x88 / 255)],
    ["#fffF", rgb(255, 255, 255)],
    ["81d4fa77", rgb(0x81, 0xd4, 0xfa, 0x77 / 255)],
    ["#81d4fa77", rgb(0x81, 0xd4, 0xfa, 0x77 / 255)],
    ["#ff000000", rgb(255, 0, 0, 0)],
    ["#ff0000ff", rgb(255, 0, 0, 1)],
    // Case-insensitive, trimmed.
    ["#81D4FA", rgb(0x81, 0xd4, 0xfa)],
    ["ABC", rgb(0xaa, 0xbb, 0xcc)],
    ["81D4FA77", rgb(0x81, 0xd4, 0xfa, 0x77 / 255)],
    ["RED", rgb(255, 0, 0)],
    ["  Transparent ", rgb(0, 0, 0, 0)],
    [" #FFF ", rgb(255, 255, 255)],
    // Empty or unset means no color.
    ["", null],
    ["   ", null],
    [undefined, null],
    [null, null],
  ];
  const NAMED = {
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

  test("parses hex colors and names; empty or unset means no color", () => {
    assertRows(parseColor, COLORS);
    assertRows(parseColor, Object.entries(NAMED));
  });

  test("rejects malformed values and non-strings, naming the value", () => {
    assertAllInvalid(
      parseColor,
      "bg_color",
      [
        ["#12", "#12345", "#1234567", "#123456789", "ggg", "#gggggg"],
        ["notacolor", "# fff", "ff ff ff", "##fff", "#red", "rgb(1,2,3)"],
        [0xff0000, { r: 1 }, true],
      ].flat(),
    );
  });

  test("is wired to bg_color / bgColor in parseOptions", () => {
    const white = rgb(255, 255, 255);
    assert.deepEqual(parseOptions({ bg_color: "#fff" }).bgColor, white);
    assert.deepEqual(parseOptions({ bgColor: "Blue" }).bgColor, rgb(0, 0, 255));
    assert.equal(parseOptions({ bg_color: "" }).bgColor, null);
    assertOptionRejected({ bg_color: "banana" }, "bg_color", '"banana"');
  });
});

describe("bg_image", () => {
  test("keeps a Buffer as the same instance, undecoded and unfrozen", () => {
    const image = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const { bgImage } = parseOptions({ bg_image: image });
    assert.equal(bgImage, image);
    assert.ok(!Object.isFrozen(bgImage));
    assert.ok(Object.isFrozen(parseOptions({ bg_image: bgImage })));
  });

  test("converts a Uint8Array to a Buffer view over the same bytes", () => {
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const { bgImage } = parseOptions({ bgImage: bytes });
    assert.ok(Buffer.isBuffer(bgImage));
    assert.deepEqual(bgImage, Buffer.from([1, 2, 3, 4]));
    bytes[0] = 9;
    assert.equal(bgImage[0], 9, "a view over the caller's bytes, not a copy");

    const backing = new Uint8Array([0xff, 1, 2, 3, 0xff]);
    const view = parseOptions({ bg_image: backing.subarray(1, 4) });
    assert.deepEqual(view.bgImage, Buffer.from([1, 2, 3]));
  });

  test("rejects anything that is not a Buffer or Uint8Array", () => {
    assertAllInvalid((value) => parseOptions({ bg_image: value }), "bg_image", [
      "background.png",
      5,
      [1, 2, 3],
      {},
      new Uint16Array(2),
    ]);
    assertOptionRejected({ bg_image: new ArrayBuffer(4) }, "bg_image");
  });

  test("cannot be combined with bg_color, but an unset or empty one is fine", () => {
    const image = Buffer.from([1]);
    assertOptionRejected(
      { bg_color: "red", bg_image: image },
      "bg_color",
      '"red"',
    );
    assertOptionRejected(
      { bgColor: "#fff", bgImage: image },
      "bg_color",
      '"#fff"',
    );
    assert.throws(
      () => parseOptions({ bg_color: "red", bg_image: image }),
      /bg_color.*bg_image/,
    );
    for (const bgColor of ["", null]) {
      const options = parseOptions({ bg_color: bgColor, bg_image: image });
      assert.equal(options.bgColor, null);
      assert.equal(options.bgImage, image);
    }
    assert.ok(parseOptions({ bg_color: "red", bg_image: undefined }).bgColor);
  });
});

describe("crop", () => {
  test("accepts booleans and true/false/1/0 strings, case-insensitively", () => {
    const rows = [
      [true, true],
      [false, false],
      ...["true", "TRUE", "True", "1", " true "].map((text) => [text, true]),
      ...["false", "FALSE", "False", "0", " 0 "].map((text) => [text, false]),
    ];
    assertRows((crop) => parseOptions({ crop }).crop, rows);
  });

  test("rejects other values", () => {
    const bad = ["yes", "no", "on", "", "2", "truthy", 1, {}];
    assertAllInvalid((crop) => parseOptions({ crop }), "crop", bad);
  });
});

describe("shadow_type and shadow_opacity", () => {
  const DEFAULT_OPACITY = {
    none: 0,
    auto: 0.5,
    car: 0.9,
    "3D": 0.5,
    drop: 0.5,
  };
  const opacityOf = (shadow_opacity, shadow_type = "car") =>
    parseOptions({ shadow_type, shadow_opacity }).shadowOpacity;

  test("an unset opacity resolves to the default for the type", () => {
    for (const [type, expected] of Object.entries(DEFAULT_OPACITY)) {
      for (const unset of [undefined, null, "auto", "none", "", " AUTO "]) {
        assert.equal(
          opacityOf(unset, type),
          expected,
          `${type} ${shown(unset)}`,
        );
      }
    }
  });

  test("an explicit opacity is a percentage and replaces the default", () => {
    assertRows(opacityOf, [
      [0, 0],
      [10, 0.1],
      [100, 1],
      ["0%", 0],
      ["40", 0.4],
      ["40%", 0.4],
      [" 75% ", 0.75],
      ["12.5", 0.125],
      [0.5, 0.005],
    ]);
    // Kept even when the type is none, so choosing a type later uses it.
    const hidden = parseOptions({ shadow_opacity: "60" });
    assert.equal(hidden.shadowType, "none");
    assert.equal(hidden.shadowOpacity, 0.6);
  });

  test("rejects opacities outside 0..100 and malformed ones, even for none", () => {
    const bad = [
      ["101", "-1", "100.1%", "-0.5%", 101, -5, Number.NaN],
      ["abc", "1e2", "5 0", "50px", "%", true, {}, [50]],
    ].flat();
    for (const type of ["none", "drop"]) {
      assertAllInvalid(
        (value) => opacityOf(value, type),
        "shadow_opacity",
        bad,
      );
    }
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
      shadow_type: "3d",
      shadow_opacity: "70%",
    });
    assert.deepEqual(options, {
      size: "full",
      format: "jpg",
      channels: "alpha",
      type: "auto",
      bgColor: rgb(0x81, 0xd4, 0xfa, 0x77 / 255),
      bgImage: null,
      crop: true,
      cropMargin: sides(px(10), pct(5), px(10), pct(5)),
      scale: 0.8,
      position: { x: 0, y: 1 },
      roi: [pct(5), pct(5), pct(95), pct(95)],
      shadowType: "3D",
      shadowOpacity: 0.7,
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
