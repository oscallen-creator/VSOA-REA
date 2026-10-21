// Rendering for the window: status text, the file table, the options panel and
// the alert dialog. Pure DOM work; nothing here talks to the main process.

const SVG_NS = "http://www.w3.org/2000/svg";
const $ = (id) => document.getElementById(id);

export const isIdle = (status) => status === "ready" || status === "finished";

/** What each background mode and the Photoshop option produce (as in main). */
export const outputFormat = ({ bgMode, usePsd }) => {
  if (bgMode === "color") return "jpg";
  return usePsd ? "psd" : "png";
};

const bgLabel = (bgMode) =>
  bgMode === "color" ? "Colored bg" : "Transparent bg";

// Elements are built with textContent only: file names and messages are
// untrusted strings.
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const icon = (name) => {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(SVG_NS, "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
};

/* Status text */

const MB = 1024 * 1024;
const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`;

export const statusText = ({ status, rows, run }, settings) => {
  const total = run?.total ?? 0;
  const done = run?.done ?? 0;
  if (status === "processing") {
    const current = Math.min(done + 1, total);
    const percent = total > 0 ? Math.round((100 * done) / total) : 0;
    return `Processing ${current} of ${total} file(s) (${percent} %)`;
  }
  if (status === "stopping") return "Stopping...";
  if (status === "finished") return `Finished ${done} of ${total} file(s) |`;
  const bg = bgLabel(settings.bgMode);
  return `${plural(rows.length, "file")}, ${bg}, Output format: ${outputFormat(settings)}`;
};

export const modelText = ({ state, received, total }) => {
  if (state === "ready") return "Model ready";
  if (state !== "downloading") return "";
  const percent = total > 0 ? Math.round((100 * received) / total) : 0;
  const sizes = `${(received / MB).toFixed(1)} of ${(total / MB).toFixed(1)}`;
  return `Downloading model… ${percent} % (${sizes} MB)`;
};

export const renderStatus = ({ queue, settings, model }) => {
  $("status-text").textContent = statusText(queue, settings);
  $("status-open").hidden = queue.status !== "finished";
  $("model-text").textContent = modelText(model);
};

/* File table */

const STATUS_ICONS = {
  ready: "dot",
  finished: "check",
  skipped: "info",
  error: "warning",
};
const STATUS_LABELS = {
  ready: "Ready",
  processing: "Processing",
  finished: "Finished",
  skipped: "Skipped",
  error: "Error",
};
const ROW_ACTIONS = {
  open: { title: "Open result", icon: "search" },
  folder: {
    title: "Open output folder",
    label: "Show in folder",
    icon: "folder",
  },
  remove: { title: "Remove from list", icon: "close" },
};

const swatch = (bgMode, color) => {
  const node = el("span", "swatch");
  if (bgMode === "color") node.style.backgroundColor = color;
  else node.classList.add("transparent");
  return node;
};

const outputNodes = (row, color) => {
  const { output } = row;
  if (row.status !== "finished" || !output) return [];
  const nodes = [];
  if (output.width && output.height) {
    nodes.push(el("span", "dims", `${output.width} × ${output.height}`));
  }
  nodes.push(swatch(output.bgMode, color));
  nodes.push(
    el("span", "bg-label", `${bgLabel(output.bgMode)}, ${output.format}`),
  );
  return nodes;
};

const rowButton = (action, row) => {
  const { title, label = title, icon: name } = ROW_ACTIONS[action];
  const button = el("button", "icon-btn");
  button.type = "button";
  button.dataset.action = action;
  button.title = title;
  button.setAttribute("aria-label", `${label}: ${row.name}`);
  button.append(icon(name));
  return button;
};

// Open/show need a result; removing is only possible between runs.
const actionsFor = (row, idle) => {
  const actions = [];
  if (row.status === "finished") actions.push("open", "folder");
  if (row.status === "skipped") actions.push("open");
  if (idle) actions.push("remove");
  return actions;
};

const fillFile = (tr, row) => {
  const name = tr.querySelector(".name");
  name.textContent = row.name;
  name.title = row.sourcePath;
  const path = tr.querySelector(".path");
  path.hidden = !row.relativePath.includes("/");
  path.textContent = path.hidden ? "" : row.relativePath;
  const note = tr.querySelector(".note");
  note.hidden = !row.message;
  note.textContent = row.message;
  note.dataset.tone = row.status === "skipped" ? "muted" : "danger";
};

const fillRow = (tr, row, ctx) => {
  tr.dataset.id = String(row.id);
  tr.dataset.status = row.status;
  const status = tr.querySelector(".status");
  status.setAttribute("aria-label", STATUS_LABELS[row.status]);
  status.replaceChildren(
    row.status === "processing"
      ? el("span", "spinner")
      : icon(STATUS_ICONS[row.status]),
  );
  fillFile(tr, row);
  tr.querySelector(".output").replaceChildren(
    ...outputNodes(row, ctx.colorOf(row)),
  );
  const buttons = actionsFor(row, ctx.idle).map((action) =>
    rowButton(action, row),
  );
  tr.querySelector(".row-actions").replaceChildren(...buttons);
};

// Everything that changes what a row looks like; equal signatures skip the
// DOM work, so a long list does not repaint on every snapshot.
const signature = (row, ctx) =>
  JSON.stringify([
    row.status,
    row.name,
    row.relativePath,
    row.message,
    row.output,
    row.output?.bgMode === "color" ? ctx.colorOf(row) : null,
    ctx.idle,
  ]);

const createRowsView = (body, template) => {
  const entries = new Map();

  const update = (row, ctx) => {
    let entry = entries.get(row.id);
    if (!entry) {
      entry = {
        tr: template.content.firstElementChild.cloneNode(true),
        sig: "",
      };
      entries.set(row.id, entry);
    }
    const sig = signature(row, ctx);
    const changed = sig !== entry.sig;
    if (changed) fillRow(entry.tr, row, ctx);
    entry.sig = sig;
    return { tr: entry.tr, changed };
  };

  const dropMissing = (live) => {
    for (const [id, entry] of entries) {
      if (live.has(id)) continue;
      entry.tr.remove();
      entries.delete(id);
    }
  };

  /** Keyed update: reuses row elements and only moves what is out of order. */
  return (rows, ctx) => {
    const live = new Set();
    let cursor = body.firstElementChild;
    for (const row of rows) {
      live.add(row.id);
      const { tr, changed } = update(row, ctx);
      if (tr === cursor) cursor = cursor.nextElementSibling;
      else body.insertBefore(tr, cursor);
      if (changed && row.status === "processing") {
        tr.scrollIntoView({ block: "nearest" });
      }
    }
    dropMissing(live);
  };
};

const syncRows = createRowsView($("rows"), $("row-template"));

/** `ctx`: `{ idle, colorOf(row) }`. */
export const renderList = ({ rows }, ctx) => {
  $("empty").hidden = rows.length > 0;
  $("table").hidden = rows.length === 0;
  syncRows(rows, ctx);
};

export const setDragging = (active) =>
  $("list-area").classList.toggle("dragging", active);

/* Buttons that depend on the app status */

export const renderControls = ({ status, rows }) => {
  const idle = isIdle(status);
  const [start, cancel] = [$("start"), $("cancel")];
  const active = document.activeElement;
  $("controls").disabled = !idle;
  $("add").disabled = !idle;
  $("clear").disabled = !idle || rows.length === 0;
  start.hidden = !idle;
  start.disabled = !rows.some((row) => row.status === "ready");
  cancel.hidden = idle;
  cancel.disabled = status === "stopping";
  // A button that disappears under the keyboard hands its focus on.
  if (active === start && !idle) cancel.focus();
  if (active === cancel && idle) (start.disabled ? $("add") : start).focus();
};

/* Options panel */

const SHADOW_DEFAULT = {
  none: "none",
  auto: "auto",
  car: 90,
  "3D": 50,
  drop: 50,
};
const OPACITY_STEPS = Array.from(
  { length: 10 },
  (_, index) => (index + 1) * 10,
);

export const buildPalette = (colors) => {
  const buttons = colors.map((color) => {
    const button = el("button");
    button.type = "button";
    button.dataset.color = color;
    button.title = color;
    button.setAttribute("aria-label", color);
    button.style.backgroundColor = color;
    return button;
  });
  $("palette").replaceChildren(...buttons);
};

const renderBackground = (settings) => {
  const isColor = settings.bgMode === "color";
  for (const button of document.querySelectorAll("[data-bg]")) {
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.bg === settings.bgMode),
    );
  }
  $("psd-field").hidden = isColor;
  $("use-psd").checked = settings.usePsd;
  $("color-field").hidden = !isColor;
  $("color-picker").value = settings.bgColor.toLowerCase();
  $("color-swatch").style.backgroundColor = settings.bgColor;
  $("color-hex").value = settings.bgColor.toUpperCase();
  for (const button of $("palette").children) {
    const picked =
      button.dataset.color.toUpperCase() === settings.bgColor.toUpperCase();
    button.setAttribute("aria-pressed", String(picked));
  }
};

const option = (value, label) => {
  const node = el("option", "", label);
  node.value = value;
  return node;
};

const opacityOptions = (shadow) => {
  const options = [];
  if (shadow === "auto") options.push(option("auto", "Mixed (Default)"));
  for (const percent of OPACITY_STEPS) {
    const suffix = percent === SHADOW_DEFAULT[shadow] ? " (Default)" : "";
    options.push(option(String(percent), `${percent}%${suffix}`));
  }
  options.push(option("custom", "Custom"));
  return options;
};

// Which choice the opacity select shows. "Custom" is explicit (ui) or implied
// by a value that is not one of the presets.
const opacityChoice = ({ shadow, shadowOpacity }, ui) => {
  if (shadow === "none") return "none";
  if (shadowOpacity === "auto") return "auto";
  const preset = OPACITY_STEPS.includes(shadowOpacity);
  return preset && !ui.customOpacity ? String(shadowOpacity) : "custom";
};

const renderShadow = (settings, ui) => {
  $("shadow").value = settings.shadow;
  const select = $("opacity");
  const choice = opacityChoice(settings, ui);
  if (select.dataset.shadow !== settings.shadow) {
    select.replaceChildren(
      ...(choice === "none"
        ? [option("none", "-")]
        : opacityOptions(settings.shadow)),
    );
    select.dataset.shadow = settings.shadow;
  }
  select.value = choice;
  select.disabled = choice === "none";
  $("custom-opacity").hidden = choice !== "custom";
  const { shadowOpacity: value } = settings;
  $("opacity-custom").value = Number.isInteger(value) ? String(value) : "";
};

/** Fills every option control from `settings`; `ui` holds view-only toggles. */
export const renderOptions = (settings, ui) => {
  renderBackground(settings);
  renderShadow(settings, ui);
  $("size").value = settings.size;
  $("quality").value = settings.quality;
  $("open-output").textContent = settings.outputPath;
};

/* Alert dialog: messages queue so none is lost while one is showing. */

const alerts = [];

const showNextAlert = () => {
  const dialog = $("alert");
  if (dialog.open || alerts.length === 0) return;
  $("alert-message").textContent = alerts.shift();
  dialog.showModal();
};

export const showAlert = (message) => {
  alerts.push(String(message));
  showNextAlert();
};

export const wireAlert = () => {
  $("alert-ok").addEventListener("click", () => $("alert").close());
  $("alert").addEventListener("close", showNextAlert);
};
