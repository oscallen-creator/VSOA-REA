// The always-on bar: a transparent, frameless, always-on-top window that never takes focus,
// so clicking it does not steal the caret from the app you are dictating into.
// Window options follow Wispr Flow's status indicator window.

import { BrowserWindow, screen } from "electron";
import path from "node:path";
import { InputShape } from "./inputShape.js";

/**
 * Transparent canvas the pill is drawn into, bottom-centered. Wispr uses a 512 px wide
 * window (taller, to fit toasts this app does not have) sitting 2 px above the work area's
 * bottom edge; the pill sits 14 px above the window bottom.
 */
export const BAR_WINDOW_SIZE = { width: 512, height: 96 };
const WORK_AREA_INSET_PX = 2;
/** How often the bar re-checks which display the cursor is on. */
const FOLLOW_CURSOR_MS = 400;

export const barBounds = (display) => {
  const area = display.workArea;
  return {
    width: BAR_WINDOW_SIZE.width,
    height: BAR_WINDOW_SIZE.height,
    x: Math.round(area.x + (area.width - BAR_WINDOW_SIZE.width) / 2),
    y: Math.round(
      area.y + area.height - WORK_AREA_INSET_PX - BAR_WINDOW_SIZE.height,
    ),
  };
};

const sameBounds = (a, b) =>
  a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

/** Moves the bar to whichever display the cursor is on. */
const followCursorDisplay = (window) => {
  const timer = setInterval(() => {
    if (window.isDestroyed()) return clearInterval(timer);
    const target = barBounds(
      screen.getDisplayNearestPoint(screen.getCursorScreenPoint()),
    );
    if (!sameBounds(target, window.getContentBounds()))
      window.setContentBounds(target);
  }, FOLLOW_CURSOR_MS);
  window.on("closed", () => clearInterval(timer));
};

export const createFlowBarWindow = ({ appRoot }) => {
  const isMac = process.platform === "darwin";
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const window = new BrowserWindow({
    ...barBounds(display),
    show: false,
    transparent: true,
    backgroundColor: "#00000000",
    hasShadow: false,
    roundedCorners: false,
    type: isMac ? "panel" : "toolbar",
    title: "Oscar's Whisper",
    frame: false,
    fullscreenable: false,
    maximizable: false,
    minimizable: false,
    resizable: false,
    movable: false,
    skipTaskbar: true,
    focusable: false,
    alwaysOnTop: true,
    ...(isMac && { hiddenInMissionControl: true }),
    webPreferences: {
      preload: path.join(appRoot, "src", "preload", "flowbar.mjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false,
    },
  });
  window.setAlwaysOnTop(true, "screen-saver");
  if (isMac) {
    window.setVisibleOnAllWorkspaces(true, {
      visibleOnFullScreen: true,
      skipTransformProcessType: true,
    });
  }

  // Windows and Linux: only the reported pill rectangles take clicks (setShape). macOS has no
  // window shapes, so Electron forwards mouse moves to the page instead, and the page turns
  // click-through off while the pointer is over the pill.
  const inputShape = isMac ? null : new InputShape();
  if (inputShape) inputShape.attach(window);
  else window.setIgnoreMouseEvents(true, { forward: true });

  window.loadFile(
    path.join(appRoot, "src", "renderer", "flowbar", "index.html"),
  );
  window.once("ready-to-show", () => {
    window.showInactive();
    inputShape?.setEnabled(true);
  });
  followCursorDisplay(window);
  return { window, inputShape };
};
