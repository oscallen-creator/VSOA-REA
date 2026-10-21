// Windows click-through for the transparent always-on-top bar.
// The renderer reports the rectangles it draws; only those receive mouse input via
// BrowserWindow.setShape, and everything else passes through to the app underneath.

const MAX_REPORTED_RECTS = 512;
export const MAX_SHAPE_RECTS = 128;
const VIEWPORT_TOLERANCE_PX = 2;
/** A 1x1 rectangle outside the window: nothing is clickable, but the shape stays applied. */
const HIDDEN_SHAPE = [{ x: -2, y: -2, width: 1, height: 1 }];

const isObject = (value) =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const isRect = (value) =>
  isObject(value) &&
  [value.x, value.y, value.width, value.height].every(
    (n) => typeof n === "number" && Number.isFinite(n),
  );
const isRectList = (value) =>
  Array.isArray(value) &&
  value.length <= MAX_REPORTED_RECTS &&
  value.every(isRect);
const rectKey = ({ x, y, width, height }) => `${x},${y},${width},${height}`;

/** Accepts `{rects, shapeRects, viewport: {width, height}}` from the renderer. */
export const isShapeReport = (report) =>
  isObject(report) &&
  isRectList(report.rects) &&
  isRectList(report.shapeRects) &&
  isObject(report.viewport) &&
  [report.viewport.width, report.viewport.height].every(
    (n) => typeof n === "number" && Number.isFinite(n) && n > 0,
  );

/** Snaps outward to whole pixels, clips to the window, drops empties, sorts and de-duplicates. */
export const clipRects = (rects, bounds) => {
  const clipped = [];
  for (const { x, y, width, height } of rects) {
    if (width <= 0 || height <= 0) continue;
    const left = Math.max(0, Math.floor(x));
    const top = Math.max(0, Math.floor(y));
    const right = Math.min(bounds.width, Math.ceil(x + width));
    const bottom = Math.min(bounds.height, Math.ceil(y + height));
    if (right > left && bottom > top) {
      clipped.push({
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
      });
    }
  }
  clipped.sort(
    (a, b) =>
      a.y - b.y || a.x - b.x || a.height - b.height || a.width - b.width,
  );
  return clipped.filter(
    (rect, i) => i === 0 || rectKey(rect) !== rectKey(clipped[i - 1]),
  );
};

/** Interactive rectangles first, then any visual-only rectangles not already covered. */
export const buildShape = ({ rects, shapeRects }, bounds) => {
  const interactive = clipRects(rects, bounds);
  const seen = new Set(interactive.map(rectKey));
  const visual = clipRects(shapeRects, bounds).filter(
    (rect) => !seen.has(rectKey(rect)),
  );
  return [...interactive, ...visual].slice(0, MAX_SHAPE_RECTS);
};

/**
 * The window ignores the mouse until a real pill shape is applied. An empty shape means
 * "rectangular", so without this the whole transparent window would swallow clicks at
 * startup; once shaped, the OS only routes input inside the shape.
 */
export class InputShape {
  #window = null;
  #enabled = false;
  #everEnabled = false;
  #rects = [];
  #appliedKey = null;
  #ignoringMouse = null;

  attach(window) {
    this.#window = window;
    this.#enabled = false;
    this.#everEnabled = false;
    this.#rects = [];
    this.#appliedKey = null;
    this.#ignoringMouse = null;
    this.#apply([]);
  }

  setEnabled(enabled) {
    this.#enabled = enabled;
    if (enabled) this.#everEnabled = true;
    this.#applyCurrent();
  }

  /** Returns false when the report is ignored (wrong sender or stale viewport size). */
  applyReport(sender, report) {
    const window = this.#window;
    if (!window || window.isDestroyed() || sender !== window.webContents)
      return false;
    if (!isShapeReport(report)) return false;
    const bounds = window.getContentBounds();
    if (
      Math.abs(report.viewport.width - bounds.width) > VIEWPORT_TOLERANCE_PX ||
      Math.abs(report.viewport.height - bounds.height) > VIEWPORT_TOLERANCE_PX
    ) {
      return false;
    }
    this.#rects = buildShape(report, bounds);
    this.#applyCurrent();
    return true;
  }

  #applyCurrent() {
    if (this.#enabled) this.#apply(this.#rects);
    else this.#apply(this.#everEnabled ? HIDDEN_SHAPE : []);
  }

  #apply(rects) {
    const window = this.#window;
    if (!window || window.isDestroyed()) return;
    const key = rects.map(rectKey).join(";");
    if (key !== this.#appliedKey) {
      window.setShape(rects);
      this.#appliedKey = key;
    }
    const ignore = !(
      this.#enabled &&
      rects === this.#rects &&
      rects.length > 0
    );
    if (ignore !== this.#ignoringMouse) {
      window.setIgnoreMouseEvents(ignore, { forward: true });
      this.#ignoringMouse = ignore;
    }
  }
}
