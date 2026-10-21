// Inserts text into whatever app has focus, the way Wispr's helper does: put the text on the
// clipboard, send the platform paste shortcut, then restore what was on the clipboard.
// If the keystroke cannot be sent, the text is left on the clipboard so it can be pasted by hand.

import { clipboard } from "electron";
import uiohookModule from "uiohook-napi";
import { debug } from "../debug.js";

const { uIOhook, UiohookKey } = uiohookModule;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait (bounded) for the user to let go of modifier keys, so they don't combine with Ctrl+V. */
const MODIFIER_RELEASE_TIMEOUT_MS = 1_000;
const MODIFIER_POLL_MS = 25;

const waitForModifierRelease = async (isModifierHeld) => {
  const deadline = Date.now() + MODIFIER_RELEASE_TIMEOUT_MS;
  while (isModifierHeld() && Date.now() < deadline)
    await delay(MODIFIER_POLL_MS);
  await delay(MODIFIER_POLL_MS);
};

/**
 * @returns {Promise<{pasted: boolean, error?: string}>}
 */
export const pasteText = async (
  text,
  { pasteDelayMs, restoreClipboardDelayMs },
  { isModifierHeld = () => false } = {},
) => {
  // Electron 44's clipboard is promise-based (modeled on navigator.clipboard).
  const previous = await clipboard.readText();
  await clipboard.writeText(text);
  try {
    await waitForModifierRelease(isModifierHeld);
    await delay(pasteDelayMs);
    const modifier =
      process.platform === "darwin" ? UiohookKey.Meta : UiohookKey.Ctrl;
    uIOhook.keyTap(UiohookKey.V, [modifier]);
  } catch (error) {
    return {
      pasted: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
  await delay(restoreClipboardDelayMs);
  // Only restore if nothing else has put new content on the clipboard in the meantime.
  const untouched = (await clipboard.readText()) === text;
  debug(
    `paste: previous clipboard ${previous.length} chars, restoring=${untouched}`,
  );
  if (untouched) await clipboard.writeText(previous);
  return { pasted: true };
};
