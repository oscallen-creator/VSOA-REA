import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { initializeCanvas, readPsd } from "ag-psd";
import {
  LAYER_NAMES,
  MAX_PSD_SIZE,
  MIN_PSD_WIDTH,
  encodePsd,
} from "../src/engine/psd.js";

// Reading back needs a canvas factory even in "imageData" mode; this one never
// draws, it only hands ag-psd plain pixel buffers.
initializeCanvas(
  () => {
    throw new Error("no canvas");
  },
  (width, height) => ({
    width,
    height,
    data: new Uint8ClampedArray(width * height * 4),
  }),
);

const decode = (buffer) => readPsd(buffer, { useImageData: true });

const W = 5;
const H = 3;
const GREEN = { r: 20, g: 200, b: 60 };

/** Every value depends on the position, so a misplaced pixel cannot hide. */
const fixture = (width, height) => {
  const count = width * height;
  const color = Buffer.alloc(count * 3);
  const original = Buffer.alloc(count * 3);
  const alpha = new Uint8Array(count);
  const shadow = new Uint8Array(count);
  for (let i = 0; i < count; i++) {
    color.set(
      [(i * 37 + 11) % 256, (i * 53 + 5) % 256, (i * 91 + 200) % 256],
      i * 3,
    );
    original.set(
      [(i * 17 + 3) % 256, (i * 29 + 90) % 256, (i * 7 + 140) % 256],
      i * 3,
    );
    alpha[i] = [0, 255, 128, 64, 200, 1, 254][i % 7];
    shadow[i] = [90, 0, 255, 128, 30][i % 5];
  }
  return { width, height, color, alpha, original, shadow };
};

const rgbOf = (rgba) => {
  const out = [];
  for (let i = 0; i < rgba.length; i += 4)
    out.push(rgba[i], rgba[i + 1], rgba[i + 2]);
  return out;
};

const channelOf = (rgba, channel) => {
  const out = [];
  for (let i = channel; i < rgba.length; i += 4) out.push(rgba[i]);
  return out;
};

const repeated = (count, value) => Array.from({ length: count }, () => value);
const rgbaAt = (rgba, i, count = 4) =>
  Array.from(rgba.subarray(i * 4, i * 4 + count));
const rgbAt = (rgb, i) => Array.from(rgb.subarray(i * 3, i * 3 + 3));

const assertClose = (actual, expected, tolerance, label) => {
  assert.equal(actual.length, expected.length, `${label} length`);
  actual.forEach((value, i) => {
    assert.ok(
      Math.abs(value - expected[i]) <= tolerance,
      `${label}[${i}]: got ${value}, expected ${expected[i]} +-${tolerance}`,
    );
  });
};

const namesOf = (psd) => psd.children.map((layer) => layer.name);
const layerNamed = (psd, name) => psd.children.find((l) => l.name === name);
const cutoutOf = (psd) => layerNamed(psd, LAYER_NAMES.cutout);

// Bottom to top, whichever of the optional layers are present.
const expectedNames = ({ original, background, shadow }) =>
  [
    original && LAYER_NAMES.original,
    background && LAYER_NAMES.background,
    shadow && LAYER_NAMES.shadow,
    LAYER_NAMES.cutout,
  ].filter(Boolean);

describe("encodePsd file and layer structure", () => {
  const input = fixture(W, H);

  test("writes a version 1 PSD header with the canvas size", () => {
    const bytes = encodePsd(input);
    assert.equal(bytes.toString("latin1", 0, 4), "8BPS");
    assert.equal(bytes.readUInt16BE(4), 1);
    assert.equal(bytes.readUInt32BE(14), H);
    assert.equal(bytes.readUInt32BE(18), W);
    assert.equal(bytes.readUInt16BE(22), 8);
    assert.equal(bytes.readUInt16BE(24), 3);
    const psd = decode(bytes);
    assert.equal(psd.width, W);
    assert.equal(psd.height, H);
  });

  test("a minimal file holds only the cutout layer", () => {
    const psd = decode(encodePsd({ ...input, original: null, shadow: null }));
    assert.deepEqual(namesOf(psd), ["Oscar's Remove BG"]);
  });

  test("a full file stacks original, background, shadows, cutout bottom to top", () => {
    const psd = decode(encodePsd({ ...input, background: GREEN }));
    assert.deepEqual(namesOf(psd), [
      "Oscar's Remove BG - Original Image",
      "Oscar's Remove BG - Background",
      "Oscar's Remove BG - Shadows",
      "Oscar's Remove BG",
    ]);
  });

  for (const hasOriginal of [false, true]) {
    for (const hasBackground of [false, true]) {
      for (const hasShadow of [false, true]) {
        const label = `original=${hasOriginal} background=${hasBackground} shadow=${hasShadow}`;
        test(`orders the layers bottom to top for ${label}`, () => {
          const psd = decode(
            encodePsd({
              ...input,
              original: hasOriginal ? input.original : null,
              background: hasBackground ? GREEN : null,
              shadow: hasShadow ? input.shadow : null,
            }),
          );
          const expected = expectedNames({
            original: hasOriginal,
            background: hasBackground,
            shadow: hasShadow,
          });
          assert.deepEqual(namesOf(psd), expected);
        });
      }
    }
  }

  test("hides only the original and masks only the cutout, all full-canvas", () => {
    const psd = decode(encodePsd({ ...input, background: GREEN }));
    for (const layer of psd.children) {
      const name = layer.name;
      assert.equal(Boolean(layer.hidden), name === LAYER_NAMES.original, name);
      assert.equal(Boolean(layer.mask), name === LAYER_NAMES.cutout, name);
      const bounds = [layer.left, layer.top, layer.right, layer.bottom];
      assert.deepEqual(bounds, [0, 0, W, H], name);
    }
  });

  test("is reproducible and treats omitted options as null", () => {
    const { width, height, color, alpha } = input;
    const bare = { width, height, color, alpha };
    const explicit = {
      ...bare,
      original: null,
      shadow: null,
      background: null,
      density: null,
    };
    assert.deepEqual(encodePsd(bare), encodePsd(explicit));
    assert.deepEqual(encodePsd(input), encodePsd(input));
  });

  test("leaves its inputs untouched", () => {
    const copy = fixture(W, H);
    encodePsd({ ...copy, background: GREEN, density: 300 });
    const reference = fixture(W, H);
    assert.deepEqual(copy.color, reference.color);
    assert.deepEqual(copy.alpha, reference.alpha);
    assert.deepEqual(copy.original, reference.original);
    assert.deepEqual(copy.shadow, reference.shadow);
  });
});

describe("encodePsd layer pixels", () => {
  const input = fixture(W, H);
  const psd = decode(encodePsd({ ...input, background: GREEN }));

  test("the cutout layer is the full colour image, opaque", () => {
    const { data, width, height } = cutoutOf(psd).imageData;
    assert.deepEqual([width, height], [W, H]);
    assert.deepEqual(rgbOf(data), [...input.color]);
    assert.deepEqual(channelOf(data, 3), repeated(W * H, 255));
  });

  test("the cutout colour is not zeroed under transparent pixels", () => {
    const { data } = cutoutOf(psd).imageData;
    const transparent = input.alpha.findIndex((a) => a === 0);
    assert.ok(transparent >= 0);
    const pixel = rgbaAt(data, transparent, 3);
    assert.deepEqual(pixel, rgbAt(input.color, transparent));
    assert.notDeepEqual(pixel, [0, 0, 0]);
  });

  test("the layer mask is full-canvas and holds the cutout alpha, every value", () => {
    const mask = cutoutOf(psd).mask;
    const bounds = [mask.left, mask.top, mask.right, mask.bottom];
    assert.deepEqual(bounds, [0, 0, W, H]);
    assert.deepEqual([mask.imageData.width, mask.imageData.height], [W, H]);
    assert.deepEqual(channelOf(mask.imageData.data, 0), [...input.alpha]);
    assert.equal(mask.defaultColor, 0);
    assert.ok(!mask.disabled);
  });

  test("the shadow layer is black with the coverage as alpha", () => {
    const { data } = layerNamed(psd, LAYER_NAMES.shadow).imageData;
    assert.deepEqual(channelOf(data, 3), [...input.shadow]);
    for (let i = 0; i < data.length; i += 4) {
      assert.deepEqual([data[i], data[i + 1], data[i + 2]], [0, 0, 0]);
    }
  });

  test("the background layer is one opaque colour", () => {
    const { data } = layerNamed(psd, LAYER_NAMES.background).imageData;
    const expected = [];
    for (let i = 0; i < W * H; i++)
      expected.push(GREEN.r, GREEN.g, GREEN.b, 255);
    assert.deepEqual([...data], expected);
  });

  test("the hidden original layer is the uploaded image, opaque", () => {
    const { data } = layerNamed(psd, LAYER_NAMES.original).imageData;
    assert.deepEqual(rgbOf(data), [...input.original]);
    assert.deepEqual(channelOf(data, 3), repeated(W * H, 255));
  });

  test("keeps rows and columns apart on a larger, non-square canvas", () => {
    const big = fixture(33, 17);
    const read = decode(encodePsd({ ...big, background: GREEN }));
    const cutout = cutoutOf(read);
    const shadow = layerNamed(read, LAYER_NAMES.shadow).imageData.data;
    for (const [x, y] of [
      [0, 0],
      [32, 0],
      [0, 16],
      [32, 16],
      [17, 9],
      [5, 12],
    ]) {
      const i = y * 33 + x;
      const label = `pixel ${x},${y}`;
      assert.deepEqual(
        rgbaAt(cutout.imageData.data, i, 3),
        rgbAt(big.color, i),
        label,
      );
      assert.equal(cutout.mask.imageData.data[i * 4], big.alpha[i], label);
      assert.equal(shadow[i * 4 + 3], big.shadow[i], label);
    }
  });
});

// Photoshop stores a flattened image with transparency blended with white (as
// ag-psd writes and reads it), which is lossy in 8 bits for translucent pixels.
// Comparing in that blended space keeps the check meaningful for every alpha.
const mattedRgb = (rgb, alphas) =>
  alphas.flatMap((a, i) =>
    [0, 1, 2].map((c) =>
      a === 0 || a === 255
        ? rgb[i * 3 + c]
        : (rgb[i * 3 + c] * a) / 255 + 255 - a,
    ),
  );

// Straight-alpha source-over in floating point, written independently of the
// implementation: background, then shadow, then cutout.
const expectedComposite = ({ color, alpha, shadow }, background) => {
  const rgb = [];
  const outAlphas = [];
  const backdrop = background
    ? [background.r, background.g, background.b]
    : null;
  alpha.forEach((a, i) => {
    const ca = a / 255;
    const sa = (shadow ? shadow[i] : 0) / 255;
    const outAlpha = backdrop ? 1 : ca + sa * (1 - ca);
    for (let c = 0; c < 3; c++) {
      const under = backdrop ? backdrop[c] * (1 - sa) : 0;
      const premultiplied = color[i * 3 + c] * ca + under * (1 - ca);
      rgb.push(outAlpha > 0 ? premultiplied / outAlpha : 0);
    }
    outAlphas.push(outAlpha * 255);
  });
  return { rgb, alpha: outAlphas };
};

const assertComposite = (data, input, background) => {
  const expected = expectedComposite(input, background);
  const alphas = channelOf(data, 3);
  assertClose(alphas, expected.alpha, 1, "alpha");
  assertClose(
    mattedRgb(rgbOf(data), alphas),
    mattedRgb(expected.rgb, alphas),
    1.5,
    "rgb",
  );
};

describe("encodePsd flattened composite", () => {
  // 7x5 has a pixel with neither cutout nor shadow, and opaque, translucent
  // and shadowed-only ones.
  const input = fixture(7, 5);
  const pixels = 7 * 5;
  const compositeOf = (options) =>
    decode(encodePsd({ ...input, ...options })).imageData;

  test("without a background it keeps real alpha: cutout over shadow", () => {
    assertComposite(compositeOf({}).data, input, null);
  });

  test("without a background, opaque cutout pixels are exactly the colour", () => {
    const { data } = compositeOf({});
    input.alpha.forEach((a, i) => {
      if (a !== 255) return;
      assert.deepEqual(rgbaAt(data, i), [...rgbAt(input.color, i), 255]);
    });
  });

  test("without a background, RGB is 0 wherever the result is transparent", () => {
    const { data } = compositeOf({});
    let clear = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i + 3] !== 0) continue;
      clear++;
      assert.deepEqual([data[i], data[i + 1], data[i + 2]], [0, 0, 0]);
    }
    assert.ok(clear > 0, "fixture should contain a clear pixel");
  });

  test("without a background, shadow-only pixels are black with the shadow alpha", () => {
    const { data } = compositeOf({});
    const i = input.alpha.findIndex((a, k) => a === 0 && input.shadow[k] > 0);
    assert.ok(i >= 0);
    assert.deepEqual(rgbaAt(data, i), [0, 0, 0, input.shadow[i]]);
  });

  test("fully clear pixels everywhere give an all-zero image", () => {
    const { data } = compositeOf({
      alpha: new Uint8Array(pixels),
      shadow: null,
    });
    assert.deepEqual([...data], repeated(pixels * 4, 0));
  });

  test("with a background it is fully opaque and blends correctly", () => {
    const { data } = compositeOf({ background: GREEN });
    assert.deepEqual(channelOf(data, 3), repeated(pixels, 255));
    assertComposite(data, input, GREEN);
  });

  test("a half-transparent pixel over a background blends to the midpoint", () => {
    const color = Buffer.from([200, 100, 0, 200, 100, 0, 200, 100, 0]);
    const alpha = new Uint8Array([128, 128, 128]);
    const background = { r: 0, g: 0, b: 100 };
    const { data: all } = decode(
      encodePsd({ width: 3, height: 1, color, alpha, background }),
    ).imageData;
    const data = all.slice(0, 4);
    const half = 128 / 255;
    assertClose(
      [...data],
      [200 * half, 100 * half, 100 * (1 - half), 255],
      1,
      "pixel",
    );
  });

  test("a shadow darkens the background only where the cutout is clear", () => {
    const color = Buffer.alloc(9, 200);
    const alpha = new Uint8Array([0, 255, 0]);
    const shadow = new Uint8Array([128, 128, 128]);
    const background = { r: 255, g: 255, b: 255 };
    const { data } = decode(
      encodePsd({ width: 3, height: 1, color, alpha, shadow, background }),
    ).imageData;
    assertClose(
      [...data],
      [127, 127, 127, 255, 200, 200, 200, 255, 127, 127, 127, 255],
      1,
      "pixels",
    );
  });
});

describe("encodePsd narrow canvases", () => {
  test("rejects widths of 1 and 2 px, which ag-psd would truncate", () => {
    for (const width of [1, 2]) {
      assert.throws(
        () => encodePsd(fixture(width, 3)),
        /at least 3 px wide, got \d px/,
      );
    }
  });

  for (const background of [null, GREEN]) {
    const label = background ? "with" : "without";
    test(`keeps a complete flattened image 3 px wide ${label} a background`, () => {
      for (const height of [1, 7]) {
        const input = fixture(MIN_PSD_WIDTH, height);
        const psd = decode(encodePsd({ ...input, background }));
        assert.equal(psd.imageData.data.length, MIN_PSD_WIDTH * height * 4);
        assertComposite(psd.imageData.data, input, background);
      }
    });
  }
});

describe("encodePsd resolution", () => {
  const { width, height, color, alpha } = fixture(W, H);
  const base = { width, height, color, alpha };

  test("writes the density to image resource 1005 as PPI over inches", () => {
    for (const density of [300, 72.5]) {
      const psd = decode(encodePsd({ ...base, density }));
      assert.deepEqual(psd.imageResources.resolutionInfo, {
        horizontalResolution: density,
        horizontalResolutionUnit: "PPI",
        widthUnit: "Inches",
        verticalResolution: density,
        verticalResolutionUnit: "PPI",
        heightUnit: "Inches",
      });
    }
  });

  test("writes no resolution when density is null or omitted", () => {
    for (const options of [base, { ...base, density: null }]) {
      const psd = decode(encodePsd(options));
      assert.equal(psd.imageResources?.resolutionInfo, undefined);
    }
  });
});

describe("encodePsd sizes", () => {
  test("a 3x1 image works with every layer", () => {
    const color = Buffer.from([10, 20, 30, 10, 20, 30, 10, 20, 30]);
    const psd = decode(
      encodePsd({
        width: 3,
        height: 1,
        color,
        alpha: new Uint8Array([255, 255, 255]),
        original: Buffer.alloc(9, 1),
        shadow: new Uint8Array([40, 40, 40]),
        background: GREEN,
        density: 96,
      }),
    );
    assert.equal(psd.width, 3);
    assert.equal(psd.height, 1);
    assert.equal(psd.children.length, 4);
    assert.deepEqual(rgbOf(cutoutOf(psd).imageData.data), [...color]);
    assert.deepEqual(
      Array.from(psd.imageData.data.slice(0, 4)),
      [10, 20, 30, 255],
    );
  });

  test("accepts the maximum side of 30000 px", () => {
    const width = MAX_PSD_SIZE;
    const psd = decode(
      encodePsd({
        width,
        height: 1,
        color: Buffer.alloc(width * 3, 9),
        alpha: new Uint8Array(width).fill(255),
      }),
    );
    assert.equal(psd.width, MAX_PSD_SIZE);
    assert.equal(psd.height, 1);
  });
});

describe("encodePsd rejections", () => {
  const ok = fixture(W, H);
  const call = (overrides) => () => encodePsd({ ...ok, ...overrides });

  test("rejects a side beyond the 30000 px PSD limit before reading pixels", () => {
    const tiny = { color: Buffer.alloc(3), alpha: new Uint8Array(1) };
    assert.throws(
      () => encodePsd({ ...tiny, width: MAX_PSD_SIZE + 1, height: 1 }),
      /width of 30001 px is over the Photoshop limit of 30000/,
    );
    assert.throws(
      () => encodePsd({ ...tiny, width: 3, height: MAX_PSD_SIZE + 1 }),
      /height of 30001 px is over the Photoshop limit/,
    );
  });

  test("rejects sides that are not whole numbers of at least 1", () => {
    for (const bad of [0, -3, 2.5, NaN, undefined, "5"]) {
      assert.throws(
        call({ width: bad }),
        /width must be a whole number/,
        String(bad),
      );
      assert.throws(
        call({ height: bad }),
        /height must be a whole number/,
        String(bad),
      );
    }
  });

  test("rejects data of the wrong length, naming what it expected", () => {
    const pixels = W * H;
    const cases = [
      [
        { color: ok.color.subarray(3) },
        /colour data has 42 values; expected 45/,
      ],
      [{ color: undefined }, /colour data has no values/],
      [
        { alpha: new Uint8Array(pixels - 1) },
        /alpha mask has 14 values; expected 15/,
      ],
      [{ alpha: new Uint8Array(pixels + 1) }, /alpha mask has 16 values/],
      [
        { original: Buffer.alloc(pixels) },
        /original image has 15 values; expected 45/,
      ],
      [
        { shadow: new Uint8Array(pixels * 4) },
        /shadow mask has 60 values; expected 15/,
      ],
    ];
    for (const [overrides, message] of cases) {
      assert.throws(call(overrides), message, String(message));
    }
  });

  test("rejects a background that is not an opaque 0-255 colour", () => {
    for (const bad of [
      { r: 256, g: 0, b: 0 },
      { r: 0, g: -1, b: 0 },
      { r: 0, g: 0, b: 1.5 },
      { r: 0, g: 0 },
    ]) {
      assert.throws(
        call({ background: bad }),
        /background needs integer/,
        JSON.stringify(bad),
      );
    }
  });

  test("rejects a density that is not a positive DPI", () => {
    for (const bad of [0, -72, NaN, Infinity, 40_000, "300"]) {
      assert.throws(call({ density: bad }), /density must be/, String(bad));
    }
  });
});
