import { describe, test } from "node:test";
import assert from "node:assert/strict";
import {
  InputShape,
  MAX_SHAPE_RECTS,
  buildShape,
  clipRects,
  isShapeReport,
} from "../src/main/flowbar/inputShape.js";

const rect = (x, y, width, height) => ({ x, y, width, height });
const BOUNDS = { width: 300, height: 100 };
const HIDDEN = [rect(-2, -2, 1, 1)];
const report = (overrides = {}) => ({
  rects: [rect(10, 10, 50, 20)],
  shapeRects: [],
  viewport: { width: 300, height: 100 },
  ...overrides,
});
const manyRects = (count, y) =>
  Array.from({ length: count }, (_, i) => rect(i, y, 1, 1));

describe("isShapeReport", () => {
  test("accepts a well-formed report, including empty rect lists", () => {
    assert.equal(isShapeReport(report()), true);
    assert.equal(isShapeReport(report({ rects: [], shapeRects: [] })), true);
  });

  test("rejects non-objects and reports with a missing or non-array rect list", () => {
    for (const value of [null, undefined, [], "report", 42, true])
      assert.equal(isShapeReport(value), false);
    assert.equal(isShapeReport({ ...report(), rects: undefined }), false);
    assert.equal(isShapeReport({ ...report(), shapeRects: undefined }), false);
    assert.equal(isShapeReport(report({ rects: { length: 0 } })), false);
  });

  test("rejects rectangles with non-finite or non-numeric fields", () => {
    const bad = [
      rect(NaN, 0, 1, 1),
      rect(0, Infinity, 1, 1),
      rect(0, 0, -Infinity, 1),
      rect("5", 0, 1, 1),
    ];
    bad.push(rect(0, 0, null, 1), { x: 0, y: 0, width: 1 }, [0, 0, 1, 1], null);
    for (const entry of bad) {
      assert.equal(isShapeReport(report({ rects: [entry] })), false);
      assert.equal(isShapeReport(report({ shapeRects: [entry] })), false);
    }
  });

  test("accepts up to 512 rectangles per list and rejects 513", () => {
    assert.equal(isShapeReport(report({ rects: manyRects(512, 0) })), true);
    assert.equal(isShapeReport(report({ rects: manyRects(513, 0) })), false);
    assert.equal(
      isShapeReport(report({ shapeRects: manyRects(513, 0) })),
      false,
    );
  });

  test("rejects a missing, zero, negative or non-finite viewport", () => {
    const sizes = [
      {},
      { width: 0, height: 100 },
      { width: 300, height: 0 },
      { width: -300, height: 100 },
    ];
    sizes.push(
      { width: NaN, height: 100 },
      { width: 300, height: Infinity },
      { width: "300", height: 100 },
    );
    for (const viewport of [undefined, null, ...sizes]) {
      assert.equal(isShapeReport(report({ viewport })), false);
    }
  });
});

describe("clipRects", () => {
  test("snaps outward to whole pixels", () => {
    assert.deepEqual(clipRects([rect(1.2, 2.7, 1, 1)], BOUNDS), [
      rect(1, 2, 2, 2),
    ]);
  });

  test("clips to the window bounds", () => {
    assert.deepEqual(clipRects([rect(-10, -5, 50, 20)], BOUNDS), [
      rect(0, 0, 40, 15),
    ]);
    assert.deepEqual(clipRects([rect(280, 90, 50, 50)], BOUNDS), [
      rect(280, 90, 20, 10),
    ]);
  });

  test("drops empty, negative-size and fully outside rectangles", () => {
    const dropped = [
      rect(10, 10, 0, 5),
      rect(10, 10, 5, 0),
      rect(10.5, 10.5, 0, 5), // would round out to 1px wide without the empty check
      rect(10.5, 10.5, 5, 0),
      rect(10, 10, -5, 5),
      rect(10, 10, 5, -5),
      rect(300, 0, 10, 10), // starts exactly at the right edge
      rect(0, 100, 10, 10), // starts exactly at the bottom edge
      rect(-20, 0, 10, 10),
      rect(-100, -100, 10, 10),
    ];
    assert.deepEqual(clipRects(dropped, BOUNDS), []);
  });

  test("sorts by y, then x", () => {
    const sorted = clipRects(
      [rect(50, 20, 5, 5), rect(10, 20, 5, 5), rect(90, 5, 5, 5)],
      BOUNDS,
    );
    assert.deepEqual(sorted, [
      rect(90, 5, 5, 5),
      rect(10, 20, 5, 5),
      rect(50, 20, 5, 5),
    ]);
  });

  test("de-duplicates rectangles, including ones that become equal after snapping", () => {
    const result = clipRects(
      [rect(1, 1, 6, 6), rect(1.1, 1.1, 5, 5), rect(1, 1, 6, 6)],
      BOUNDS,
    );
    assert.deepEqual(result, [rect(1, 1, 6, 6)]);
  });

  test("returns an empty list for no input", () => {
    assert.deepEqual(clipRects([], BOUNDS), []);
  });
});

describe("buildShape", () => {
  test("lists interactive rectangles first, then new visual ones, each group sorted", () => {
    const shape = buildShape(
      {
        rects: [rect(200, 80, 10, 10)],
        shapeRects: [rect(0, 50, 10, 10), rect(0, 0, 10, 10)],
      },
      BOUNDS,
    );
    assert.deepEqual(shape, [
      rect(200, 80, 10, 10),
      rect(0, 0, 10, 10),
      rect(0, 50, 10, 10),
    ]);
  });

  test("omits visual rectangles already covered by an interactive one", () => {
    const shape = buildShape(
      {
        rects: [rect(10, 10, 20, 20)],
        shapeRects: [rect(10.5, 10, 19, 20), rect(100, 10, 5, 5)],
      },
      BOUNDS,
    );
    assert.deepEqual(shape, [rect(10, 10, 20, 20), rect(100, 10, 5, 5)]);
  });

  test("caps the result at MAX_SHAPE_RECTS, keeping interactive rectangles first", () => {
    assert.equal(MAX_SHAPE_RECTS, 128);
    const shape = buildShape(
      { rects: manyRects(100, 0), shapeRects: manyRects(100, 50) },
      BOUNDS,
    );
    assert.equal(shape.length, MAX_SHAPE_RECTS);
    assert.deepEqual(shape.slice(0, 100), manyRects(100, 0));
    assert.deepEqual(shape.slice(100), manyRects(28, 50));
  });

  test("drops visual rectangles entirely when interactive ones fill the cap", () => {
    const shape = buildShape(
      { rects: manyRects(200, 0), shapeRects: manyRects(5, 50) },
      BOUNDS,
    );
    assert.deepEqual(shape, manyRects(MAX_SHAPE_RECTS, 0));
  });
});

describe("InputShape", () => {
  const createWindow = () => {
    const shapes = [];
    const ignores = [];
    const window = {
      webContents: {},
      destroyed: false,
      isDestroyed: () => window.destroyed,
      getContentBounds: () => ({ x: 0, y: 0, width: 300, height: 100 }),
      setShape: (rects) => shapes.push(rects),
      setIgnoreMouseEvents: (...args) => ignores.push(args),
    };
    return { window, shapes, ignores, sender: window.webContents };
  };
  const attached = () => {
    const env = createWindow();
    const inputShape = new InputShape();
    inputShape.attach(env.window);
    return { ...env, inputShape };
  };

  test("attach clears the shape and enables forwarded click-through", () => {
    const { shapes, ignores } = attached();
    assert.deepEqual(shapes, [[]]);
    assert.deepEqual(ignores, [[true, { forward: true }]]);
  });

  test("accepts mouse input only while an enabled, non-empty pill shape is applied", () => {
    const { inputShape, sender, ignores } = attached();
    inputShape.setEnabled(true);
    assert.deepEqual(ignores.at(-1), [true, { forward: true }]); // no shape reported yet
    inputShape.applyReport(sender, report());
    assert.deepEqual(ignores.at(-1), [false, { forward: true }]);
    inputShape.setEnabled(false);
    assert.deepEqual(ignores.at(-1), [true, { forward: true }]);
    assert.equal(ignores.length, 3); // unchanged states are not re-sent
  });

  test("applies the clipped report only while enabled", () => {
    const { inputShape, sender, shapes } = attached();
    const next = report({
      rects: [rect(10, 10, 50, 20)],
      shapeRects: [rect(0, 0, 400, 5)],
    });
    assert.equal(inputShape.applyReport(sender, next), true);
    assert.deepEqual(shapes, [[]]); // stored, not applied while disabled
    inputShape.setEnabled(true);
    assert.deepEqual(shapes.at(-1), [rect(10, 10, 50, 20), rect(0, 0, 300, 5)]);
  });

  test("disabling after having been enabled hides the shape off-window", () => {
    const { inputShape, sender, shapes } = attached();
    inputShape.applyReport(sender, report());
    inputShape.setEnabled(true);
    inputShape.setEnabled(false);
    assert.deepEqual(shapes.at(-1), HIDDEN);
    inputShape.setEnabled(true);
    assert.deepEqual(shapes.at(-1), [rect(10, 10, 50, 20)]);
  });

  test("disabling when never enabled leaves the empty shape untouched", () => {
    const { inputShape, shapes } = attached();
    inputShape.setEnabled(false);
    assert.deepEqual(shapes, [[]]);
  });

  test("an identical shape is not applied twice, a changed one is", () => {
    const { inputShape, sender, shapes } = attached();
    inputShape.setEnabled(true);
    inputShape.applyReport(sender, report());
    inputShape.applyReport(sender, report());
    inputShape.setEnabled(true);
    assert.equal(shapes.length, 2); // initial [] plus one real shape
    inputShape.applyReport(sender, report({ rects: [rect(20, 10, 50, 20)] }));
    assert.equal(shapes.length, 3);
  });

  test("ignores reports from a different sender and malformed reports", () => {
    const { inputShape, sender, shapes } = attached();
    inputShape.setEnabled(true);
    assert.equal(inputShape.applyReport({}, report()), false);
    assert.equal(inputShape.applyReport(sender, { rects: [] }), false);
    assert.equal(inputShape.applyReport(sender, null), false);
    assert.deepEqual(shapes, [[]]);
  });

  test("rejects a viewport more than 2px off the window, accepts one within 2px", () => {
    const { inputShape, sender, shapes } = attached();
    inputShape.setEnabled(true);
    assert.equal(
      inputShape.applyReport(
        sender,
        report({ viewport: { width: 303, height: 100 } }),
      ),
      false,
    );
    assert.equal(
      inputShape.applyReport(
        sender,
        report({ viewport: { width: 300, height: 97 } }),
      ),
      false,
    );
    assert.deepEqual(shapes, [[]]);
    assert.equal(
      inputShape.applyReport(
        sender,
        report({ viewport: { width: 302, height: 98 } }),
      ),
      true,
    );
    assert.deepEqual(shapes.at(-1), [rect(10, 10, 50, 20)]);
  });

  test("does nothing for a destroyed window", () => {
    const { inputShape, sender, shapes, window } = attached();
    window.destroyed = true;
    assert.equal(inputShape.applyReport(sender, report()), false);
    inputShape.setEnabled(true);
    assert.deepEqual(shapes, [[]]);
  });

  test("without an attached window, reports are rejected and enabling is harmless", () => {
    const inputShape = new InputShape();
    assert.equal(inputShape.applyReport({}, report()), false);
    assert.doesNotThrow(() => inputShape.setEnabled(true));
  });

  test("re-attaching resets enabled state and stored rectangles", () => {
    const { inputShape, sender } = attached();
    inputShape.applyReport(sender, report());
    inputShape.setEnabled(true);
    const second = createWindow();
    inputShape.attach(second.window);
    inputShape.setEnabled(false);
    assert.deepEqual(second.shapes, [[]]);
    inputShape.setEnabled(true);
    assert.deepEqual(second.shapes, [[]]); // no report yet for the new window
    assert.deepEqual(second.ignores, [[true, { forward: true }]]);
  });
});
