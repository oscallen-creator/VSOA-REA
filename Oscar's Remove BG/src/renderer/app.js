// Window controller: loads the state, subscribes to updates and turns clicks,
// drops and form changes into calls on the preload API (window.removeBg).
// The main process owns the rules; every settings change re-renders from the
// settings it returns.

import {
  buildPalette,
  isIdle,
  renderControls,
  renderList,
  renderOptions,
  renderStatus,
  setDragging,
  showAlert,
  wireAlert,
} from "./view.js";

const api = window.removeBg;
const $ = (id) => document.getElementById(id);
const HEX_COLOR = /^#[0-9A-F]{6}$/;
// Where "Custom" starts when the shadow's opacity is not a number yet.
const CUSTOM_OPACITY_START = 50;

const app = {
  queue: null,
  settings: null,
  model: null,
  // View-only: the opacity select shows "Custom" even for a preset value.
  ui: { customOpacity: false },
  // The queue snapshot does not carry the background color a row was made
  // with, so it is remembered when the row is first seen running.
  colors: new Map(),
};

const rememberColors = () => {
  const seen = new Set();
  for (const row of app.queue.rows) {
    seen.add(row.id);
    if (row.status === "ready") app.colors.delete(row.id);
    else if (!app.colors.has(row.id))
      app.colors.set(row.id, app.settings.bgColor);
  }
  for (const id of app.colors.keys()) {
    if (!seen.has(id)) app.colors.delete(id);
  }
};

const rowContext = () => ({
  idle: isIdle(app.queue.status),
  colorOf: (row) =>
    row.output?.bgColor ?? app.colors.get(row.id) ?? app.settings.bgColor,
});

const renderQueue = () => {
  rememberColors();
  renderList(app.queue, rowContext());
  renderControls(app.queue);
  renderStatus(app);
};

const renderSettings = () => {
  renderOptions(app.settings, app.ui);
  renderQueue();
};

/* Actions */

const reportFailure = (error) => showAlert(error?.message ?? String(error));

// Handlers may be async; a rejected IPC call becomes an alert, not silence.
const on = (target, type, handler) =>
  target.addEventListener(type, async (event) => {
    try {
      await handler(event);
    } catch (error) {
      reportFailure(error);
    }
  });

/** Settings come back from main with its rules applied (e.g. shadow resets opacity). */
const apply = async (patch) => {
  app.settings = await api.updateSettings(patch);
  renderSettings();
};

const showAddResult = (result) => {
  if (result?.message) showAlert(result.message);
};

// shell.openPath resolves to "" on success, otherwise to the reason.
const showOpenResult = (message) => {
  if (message) showAlert(message);
};

const openOutput = async () => showOpenResult(await api.openOutputFolder());

const changeOutput = async () => {
  app.settings = await api.pickOutputFolder();
  renderSettings();
};

const ROW_ACTIONS = {
  open: async (id) => showOpenResult(await api.openResult(id)),
  folder: (id) => api.showInFolder(id),
  remove: (id) => api.remove(id),
};

const onRowClick = (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  return ROW_ACTIONS[button.dataset.action](
    Number(button.closest("tr").dataset.id),
  );
};

/* Options */

const chooseOpacity = (choice) => {
  app.ui.customOpacity = choice === "custom";
  if (choice === "auto") return apply({ shadowOpacity: "auto" });
  if (choice !== "custom") return apply({ shadowOpacity: Number(choice) });
  // Keep the input and the stored value in agreement from the start.
  if (Number.isInteger(app.settings.shadowOpacity)) return renderSettings();
  return apply({ shadowOpacity: CUSTOM_OPACITY_START });
};

const commitCustomOpacity = (text) => {
  const percent = Math.round(Number(text));
  if (text.trim() === "" || Number.isNaN(percent)) return renderSettings();
  return apply({ shadowOpacity: Math.min(100, Math.max(0, percent)) });
};

// Anything that is not #RRGGBB puts the current color back in the field.
const commitColor = (text) => {
  const color = text.trim().toUpperCase();
  if (HEX_COLOR.test(color) && color !== app.settings.bgColor) {
    return apply({ bgColor: color });
  }
  return renderSettings();
};

const wireColor = () => {
  const picker = $("color-picker");
  // Preview while dragging inside the native picker; apply once it settles.
  on(picker, "input", () => {
    $("color-swatch").style.backgroundColor = picker.value;
    $("color-hex").value = picker.value.toUpperCase();
  });
  on(picker, "change", () => commitColor(picker.value));
  // Chromium fires "change" for Enter in an edited text field as well.
  on($("color-hex"), "change", (event) => commitColor(event.target.value));
  on($("palette"), "click", (event) => {
    const button = event.target.closest("button[data-color]");
    if (button) return commitColor(button.dataset.color);
  });
};

const wireOptions = () => {
  for (const button of document.querySelectorAll("[data-bg]")) {
    on(button, "click", () => {
      if (button.dataset.bg !== app.settings.bgMode) {
        return apply({ bgMode: button.dataset.bg });
      }
    });
  }
  on($("use-psd"), "change", (event) =>
    apply({ usePsd: event.target.checked }),
  );
  on($("shadow"), "change", (event) => {
    app.ui.customOpacity = false;
    return apply({ shadow: event.target.value });
  });
  on($("opacity"), "change", (event) => chooseOpacity(event.target.value));
  on($("opacity-custom"), "change", (event) =>
    commitCustomOpacity(event.target.value),
  );
  on($("size"), "change", (event) => apply({ size: event.target.value }));
  on($("quality"), "change", (event) => apply({ quality: event.target.value }));
  on($("change-output"), "click", changeOutput);
  wireColor();
};

/* Adding files */

const pickFiles = async () => showAddResult(await api.pickFiles());

// An array of File objects, not the live FileList, crosses the context bridge.
const addDropped = async (files) =>
  showAddResult(await api.addFiles(Array.from(files)));

const hasFiles = (event) =>
  event.dataTransfer?.types.includes("Files") === true;
const accepting = () => app.queue !== null && isIdle(app.queue.status);

// preventDefault on dragover and drop is unconditional: otherwise Electron
// would navigate to the dropped file. Only the highlight and the add are gated.
const wireDrop = () => {
  let depth = 0;
  const refresh = () => setDragging(depth > 0 && accepting());
  document.addEventListener("dragenter", (event) => {
    event.preventDefault();
    if (hasFiles(event)) depth += 1;
    refresh();
  });
  document.addEventListener("dragleave", (event) => {
    if (hasFiles(event)) depth = Math.max(0, depth - 1);
    refresh();
  });
  document.addEventListener("dragover", (event) => {
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect =
        hasFiles(event) && accepting() ? "copy" : "none";
    }
  });
  on(document, "drop", (event) => {
    event.preventDefault();
    depth = 0;
    refresh();
    const files = event.dataTransfer?.files;
    if (accepting() && files?.length > 0) return addDropped(files);
  });
};

const wireActions = () => {
  on($("add"), "click", pickFiles);
  on($("empty"), "click", pickFiles);
  on($("start"), "click", () => api.start());
  on($("cancel"), "click", () => api.cancel());
  on($("clear"), "click", () => api.clear());
  on($("open-output"), "click", openOutput);
  on($("status-open"), "click", openOutput);
  on($("rows"), "click", onRowClick);
};

const subscribe = () => {
  api.onQueue((snapshot) => {
    app.queue = snapshot;
    renderQueue();
  });
  api.onModel((status) => {
    app.model = status;
    renderStatus(app);
  });
  api.onAlert(({ message }) => showAlert(message));
};

const init = async () => {
  // Alerts and drops work before the state arrives; a stray drop must never
  // navigate the window.
  wireAlert();
  wireDrop();
  const state = await api.getState();
  Object.assign(app, {
    queue: state.queue,
    settings: state.settings,
    model: state.model,
  });
  subscribe();
  buildPalette(state.palette);
  $("brand").title = `Version ${state.version}`;
  wireActions();
  wireOptions();
  renderSettings();
};

init().catch(reportFailure);
