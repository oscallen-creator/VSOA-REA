// Inserts text into whatever app has focus: put it on the clipboard, send the platform paste
// shortcut, then put the previous clipboard text back if nothing else replaced it meanwhile.

import { clipboard } from "electron";
import uiohookModule from "uiohook-napi";

const { uIOhook, UiohookKey } = uiohookModule;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const pasteText = async (
  text,
  { pasteDelayMs, restoreClipboardDelayMs },
) => {
  const previous = clipboard.readText();
  clipboard.writeText(text);
  await delay(pasteDelayMs);
  const modifier =
    process.platform === "darwin" ? UiohookKey.Meta : UiohookKey.Ctrl;
  uIOhook.keyTap(UiohookKey.V, [modifier]);
  await delay(restoreClipboardDelayMs);
  if (clipboard.readText() === text) clipboard.writeText(previous);
};
