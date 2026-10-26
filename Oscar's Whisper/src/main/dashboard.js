// The dashboard: recent dictations and the push-to-talk keys. One window, opened from the
// bar's right-click menu and reused while it is open.

import { app, BrowserWindow } from "electron";
import path from "node:path";

let window = null;

export const dashboardContents = () =>
  window && !window.isDestroyed() ? window.webContents : null;

export const openDashboard = ({ appRoot, onClosed }) => {
  if (!dashboardContents()) {
    window = new BrowserWindow({
      width: 520,
      height: 600,
      minWidth: 380,
      minHeight: 320,
      title: "Oscar's Whisper",
      show: false,
      webPreferences: {
        preload: path.join(appRoot, "src", "preload", "dashboard.mjs"),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false,
      },
    });
    window.loadFile(
      path.join(appRoot, "src", "renderer", "dashboard", "index.html"),
    );
    window.once("ready-to-show", () => window.show());
    window.on("closed", onClosed);
  } else window.show();
  // Without a Dock icon (macOS), the app has to bring itself to the front.
  app.focus({ steal: true });
  window.focus();
};
