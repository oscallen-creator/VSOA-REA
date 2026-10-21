import { before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { initializeCanvas, readPsd } from "ag-psd";
import { LAYER_NAMES } from "../src/engine/psd.js";
import {
  H,
  SUBJECT,
  W,
  gradientImage,
  imageRgb,
  render,
} from "./compose.helpers.test.js";

// Reading back needs image data; ag-psd's canvas is never used here.
before(() =>
  initializeCanvas(
    () => {
      throw new Error("no canvas");
    },
    (width, height) => ({
      width,
      height,
      data: new Uint8ClampedArray(width * height * 4),
    }),
  ),
);

const read = (buffer) => readPsd(buffer, { useImageData: true });
const names = (psd) => psd.children.map((layer) => layer.name);
const cutout = (psd) =>
  psd.children.find((layer) => layer.name === LAYER_NAMES.cutout);
const at = (data, width, x, y) => {
  const i = (y * width + x) * 4;
  return [...data.subarray(i, i + 4)];
};

describe("compose with format psd", () => {
  test("returns a layered PSD whose cutout keeps every colour under its mask", async () => {
    const result = await render({ format: "psd" });
    assert.equal(result.format, "psd");
    assert.equal(result.mime, "image/vnd.adobe.photoshop");
    assert.equal(result.buffer.subarray(0, 4).toString("latin1"), "8BPS");
    const psd = read(result.buffer);
    assert.deepEqual([psd.width, psd.height], [W, H]);
    assert.deepEqual(names(psd), [LAYER_NAMES.original, LAYER_NAMES.cutout]);
    const layer = cutout(psd);
    const image = gradientImage(W, H);
    // Outside the subject the colour is kept (the mask hides it), so the mask
    // can be painted back in Photoshop.
    assert.deepEqual(
      at(layer.imageData.data, W, 2, 2).slice(0, 3),
      imageRgb(image, 2, 2),
    );
    assert.equal(at(layer.mask.imageData.data, W, 2, 2)[0], 0);
    const inside = [SUBJECT.x + 5, SUBJECT.y + 5];
    assert.equal(at(layer.mask.imageData.data, W, ...inside)[0], 255);
  });

  test("puts the shadow on its own layer instead of into the cutout", async () => {
    const psd = read(
      (await render({ format: "psd", shadowType: "drop", shadowOpacity: 0.5 }))
        .buffer,
    );
    assert.deepEqual(names(psd), [
      LAYER_NAMES.original,
      LAYER_NAMES.shadow,
      LAYER_NAMES.cutout,
    ]);
    // The cutout mask is the subject alone: no shadow pixels below-right.
    const mask = cutout(psd).mask.imageData.data;
    const belowRight = [SUBJECT.x + SUBJECT.w + 1, SUBJECT.y + SUBJECT.h + 1];
    assert.equal(at(mask, W, ...belowRight)[0], 0);
  });

  test("adds a background layer for a colour background", async () => {
    const psd = read(
      (
        await render({
          format: "psd",
          bgColor: { r: 0, g: 0, b: 255, alpha: 1 },
        })
      ).buffer,
    );
    assert.deepEqual(names(psd), [
      LAYER_NAMES.original,
      LAYER_NAMES.background,
      LAYER_NAMES.cutout,
    ]);
    assert.deepEqual(at(psd.imageData.data, W, 1, 1), [0, 0, 255, 255]);
  });

  test("refuses a background image", async () => {
    await assert.rejects(
      render({ format: "psd", bgImage: Buffer.from("not decoded") }),
      /background colour, not a background image/,
    );
  });

  test("writes the input DPI into the PSD", async () => {
    const psd = read(
      (await render({ format: "psd" }, { density: 300 })).buffer,
    );
    assert.equal(psd.imageResources.resolutionInfo.horizontalResolution, 300);
  });

  test("channels alpha still returns the PNG matte", async () => {
    const result = await render({ format: "psd", channels: "alpha" });
    assert.equal(result.format, "png");
  });
});
