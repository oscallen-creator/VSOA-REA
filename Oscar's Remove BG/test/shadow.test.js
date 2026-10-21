import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { SHADOW_STYLES, renderShadow } from "../src/engine/shadow.js";

const W = 320;
const H = 240;
const BOX = { left: 80, top: 40, width: 160, height: 120 };
const TYPES = ["drop", "car", "3D", "auto"];
const CONTACT_TYPES = ["car", "3D", "auto"];

/** A canvas-sized mask with every rectangle filled opaque. */
const maskOf = (rects, width = W, height = H) => {
  const alpha = new Uint8Array(width * height);
  for (const { left, top, width: w, height: h } of rects) {
    for (let y = top; y < top + h; y++) {
      alpha.fill(255, y * width + left, y * width + left + w);
    }
  }
  return alpha;
};

const cast = (type, opacity = 1, { box = BOX, alpha = maskOf([box]) } = {}) =>
  renderShadow({ alpha, width: W, height: H, box, type, opacity });

/** Mass-weighted centroid, spread (std deviation), peak and extent. */
const measure = (plane, width = W) => {
  let mass = 0;
  let sx = 0;
  let sy = 0;
  let max = 0;
  const extent = { minX: width, maxX: -1, minY: Infinity, maxY: -1 };
  plane.forEach((value, i) => {
    if (value === 0) return;
    const x = i % width;
    const y = Math.floor(i / width);
    mass += value;
    sx += value * x;
    sy += value * y;
    max = Math.max(max, value);
    extent.minX = Math.min(extent.minX, x);
    extent.maxX = Math.max(extent.maxX, x);
    extent.minY = Math.min(extent.minY, y);
    extent.maxY = Math.max(extent.maxY, y);
  });
  const cx = sx / mass;
  const cy = sy / mass;
  let vx = 0;
  let vy = 0;
  plane.forEach((value, i) => {
    vx += value * ((i % width) - cx) ** 2;
    vy += value * (Math.floor(i / width) - cy) ** 2;
  });
  return {
    mass,
    max,
    cx,
    cy,
    sdX: Math.sqrt(vx / mass),
    sdY: Math.sqrt(vy / mass),
    ...extent,
  };
};

describe("SHADOW_STYLES", () => {
  test("is frozen and covers every type that draws something", () => {
    assert.deepEqual(Object.keys(SHADOW_STYLES).sort(), [...TYPES].sort());
    assert.ok(Object.isFrozen(SHADOW_STYLES));
    for (const style of Object.values(SHADOW_STYLES)) {
      assert.ok(Object.isFrozen(style));
    }
  });

  test("makes a car's contact shadow flatter and tighter than 3D", () => {
    assert.ok(SHADOW_STYLES.car.squash < SHADOW_STYLES.auto.squash);
    assert.ok(SHADOW_STYLES.auto.squash < SHADOW_STYLES["3D"].squash);
    assert.ok(SHADOW_STYLES.car.blur < SHADOW_STYLES.auto.blur);
    assert.ok(SHADOW_STYLES.auto.blur < SHADOW_STYLES["3D"].blur);
  });
});

describe("renderShadow nothing to draw", () => {
  test("returns null for type none or opacity 0", async () => {
    assert.equal(await cast("none", 1), null);
    for (const type of TYPES) assert.equal(await cast(type, 0), null, type);
  });

  test("rejects an unknown type and an opacity outside 0..1", async () => {
    await assert.rejects(cast("glow", 1), /Unknown shadow type "glow"/);
    for (const opacity of [-0.1, 1.5, Number.NaN]) {
      await assert.rejects(cast("drop", opacity), RangeError);
    }
  });
});

describe("renderShadow output", () => {
  test("is a canvas-sized Uint8Array, deterministic, and leaves alpha alone", async () => {
    const alpha = maskOf([BOX]);
    const before = Uint8Array.from(alpha);
    for (const type of TYPES) {
      const first = await cast(type, 0.7, { alpha });
      assert.ok(first instanceof Uint8Array, type);
      assert.equal(first.length, W * H, type);
      assert.deepEqual(first, await cast(type, 0.7, { alpha }), type);
    }
    assert.deepEqual(alpha, before);
  });

  test("scales the coverage by the opacity", async () => {
    for (const type of TYPES) {
      const full = measure(await cast(type, 1));
      const half = measure(await cast(type, 0.5));
      assert.ok(full.max > 128, `${type} full peak ${full.max}`);
      assert.ok(half.max <= 128, `${type} half peak ${half.max}`);
      assert.ok(Math.abs(half.mass / full.mass - 0.5) < 0.01, type);
    }
  });

  test("follows the silhouette rather than its box", async () => {
    // Two pillars with a wide gap between them.
    const pillars = [
      { ...BOX, width: 50 },
      { ...BOX, left: BOX.left + 110, width: 50 },
    ];
    for (const type of ["drop", "car"]) {
      const plane = await cast(type, 1, { alpha: maskOf(pillars) });
      const row = type === "drop" ? BOX.top + 60 : BOX.top + BOX.height - 1;
      const at = (x) => plane[row * W + x];
      const gap = at(BOX.left + 80);
      assert.ok(gap < at(BOX.left + 25) / 2, `${type} gap ${gap}`);
    }
  });
});

describe("drop shadow", () => {
  test("sits offset to the lower right of the subject", async () => {
    const stats = measure(await cast("drop"));
    // Subject centroid is the middle of the box; the offset is 2% x 3%.
    const subjectX = BOX.left + (BOX.width - 1) / 2;
    const subjectY = BOX.top + (BOX.height - 1) / 2;
    const dx = Math.round(0.02 * BOX.width);
    const dy = Math.round(0.03 * BOX.height);
    assert.ok(Math.abs(stats.cx - subjectX - dx) < 0.5, `cx ${stats.cx}`);
    assert.ok(Math.abs(stats.cy - subjectY - dy) < 0.5, `cy ${stats.cy}`);
    // It peeks out on the right and bottom more than on the left and top.
    assert.ok(stats.maxX - (BOX.left + BOX.width - 1) > BOX.left - stats.minX);
    assert.ok(stats.maxY - (BOX.top + BOX.height - 1) > BOX.top - stats.minY);
  });

  test("blurs by 1.5% of the longer side", async () => {
    const plane = await cast("drop");
    const sigma = 0.015 * BOX.width;
    const reach = Math.ceil(3 * sigma) + 1;
    const dx = Math.round(0.02 * BOX.width);
    const stats = measure(plane);
    assert.ok(stats.minX >= BOX.left + dx - reach, `minX ${stats.minX}`);
    assert.ok(stats.maxX <= BOX.left + BOX.width + dx + reach);
    // Fully opaque well inside, falling off across the edge.
    const row = BOX.top + 60;
    assert.ok(plane[row * W + BOX.left + 80] >= 250);
    assert.ok(plane[row * W + BOX.left + dx + BOX.width + 1] < 255);
  });
});

describe("contact shadows", () => {
  const bottom = BOX.top + BOX.height;

  for (const type of CONTACT_TYPES) {
    test(`${type} lies under the subject's base, within its width`, async () => {
      const stats = measure(await cast(type));
      const sigma = Math.max(1, SHADOW_STYLES[type].blur * BOX.width);
      const lift = Math.round(0.01 * BOX.height);
      // Centred just above the base, so nothing reaches the subject's middle.
      assert.ok(Math.abs(stats.cy - (bottom - lift)) < 1.5, `cy ${stats.cy}`);
      assert.ok(stats.minY > BOX.top + BOX.height / 2);
      assert.ok(stats.minX >= BOX.left - 3 * sigma - 1, `minX ${stats.minX}`);
      assert.ok(stats.maxX <= BOX.left + BOX.width + 3 * sigma + 1);
      assert.ok(Math.abs(stats.cx - (BOX.left + (BOX.width - 1) / 2)) < 0.5);
    });
  }

  test("car is tighter than auto, and auto tighter than 3D", async () => {
    const [car, auto, flat] = await Promise.all(
      ["car", "auto", "3D"].map(async (type) => measure(await cast(type))),
    );
    for (const [tight, loose] of [
      [car, auto],
      [auto, flat],
    ]) {
      assert.ok(tight.sdX < loose.sdX, `${tight.sdX} vs ${loose.sdX}`);
      assert.ok(tight.sdY < loose.sdY, `${tight.sdY} vs ${loose.sdY}`);
    }
  });

  test("squashes to at least two rows for a very flat subject", async () => {
    const flat = { left: 100, top: 100, width: 120, height: 3 };
    for (const type of CONTACT_TYPES) {
      const stats = measure(await cast(type, 1, { box: flat }));
      assert.ok(stats.mass > 0, type);
      assert.ok(stats.maxY >= flat.top + flat.height - 2, type);
    }
  });
});

describe("renderShadow at the canvas edge", () => {
  test("clips a subject that fills the canvas", async () => {
    const whole = { left: 0, top: 0, width: W, height: H };
    for (const type of TYPES) {
      const plane = await cast(type, 1, { box: whole, alpha: maskOf([whole]) });
      assert.equal(plane.length, W * H, type);
      assert.ok(measure(plane).mass > 0, type);
    }
  });

  test("keeps the part of a shadow that falls inside", async () => {
    const corner = { left: W - 100, top: H - 80, width: 100, height: 80 };
    const alpha = maskOf([corner]);
    for (const type of TYPES) {
      const stats = measure(await cast(type, 1, { box: corner, alpha }));
      assert.ok(stats.mass > 0, type);
      assert.ok(stats.maxX <= W - 1 && stats.maxY <= H - 1, type);
      assert.ok(stats.minX >= corner.left - 20, type);
    }
  });

  test("works on tiny canvases", async () => {
    for (const size of [1, 2, 4]) {
      const box = { left: 0, top: 0, width: size, height: size };
      const alpha = new Uint8Array(size * size).fill(255);
      for (const type of TYPES) {
        const plane = await renderShadow({
          alpha,
          width: size,
          height: size,
          box,
          type,
          opacity: 1,
        });
        assert.equal(plane.length, size * size, `${type} ${size}`);
        assert.ok(
          plane.some((value) => value > 0),
          `${type} ${size}`,
        );
      }
    }
  });
});
