// The always-on bar: a transparent, frameless, always-on-top window that never takes focus,
// so clicking it does not steal the caret from the app you are dictating into.
// Window options follow Wispr Flow's status indicator window.

import { BrowserWindow, screen } from "electron";
import path from "node:path";
import { InputShape } from "./inputShape.js";

/** Transparent canvas the pill is drawn into; the pill itself is smaller and centered. */
export const BAR_WINDOW_SIZE = { width: 240, height: 64 };
const BOTTOM_MARGIN_PX = 12;

export const barBounds = (display) => {
  const area = display.workArea;
  return {
    width: BAR_WINDOW_SIZE.width,
    height: BAR_WINDOW_SIZE.height,
    x: Math.round(area.x + (area.width - BAR_WINDOW_SIZE.width) / 2),
    y: Math.round(
      area.y + area.height - BAR_WINDOW_SIZE.height - BOTTOM_MARGIN_PX,
    ),
  };
};

export const createFlowBarWindow = ({ appRoot }) => {
  const isMac = process.platform === "darwin";
  const isWindows = process.platform === "win32";
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

  // Windows: only the reported pill rectangles take clicks. Elsewhere, Electron forwards
  // mouse moves to the page, which turns click-through off while the pointer is over the pill.
  const inputShape = isWindows ? new InputShape() : null;
  if (inputShape) inputShape.attach(window);
  else window.setIgnoreMouseEvents(true, { forward: true });

  window.loadFile(
    path.join(appRoot, "src", "renderer", "flowbar", "index.html"),
  );
  window.once("ready-to-show", () => {
    window.showInactive();
    inputShape?.setEnabled(true);
  });
  return { window, inputShape };
};
