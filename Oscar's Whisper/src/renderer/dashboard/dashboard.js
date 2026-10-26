// Shows recent dictations and lets the user press new push-to-talk keys.

const KEY_NAMES = {
  darwin: {
    ctrl: "⌃ Control",
    alt: "⌥ Option",
    shift: "⇧ Shift",
    win: "⌘ Command",
    rctrl: "Right ⌃ Control",
    ralt: "Right ⌥ Option",
    rshift: "Right ⇧ Shift",
    rwin: "Right ⌘ Command",
  },
  other: {
    ctrl: "Ctrl",
    alt: "Alt",
    shift: "Shift",
    win: "Win",
    rctrl: "Right Ctrl",
    ralt: "Right Alt",
    rshift: "Right Shift",
    rwin: "Right Win",
  },
};
const KEY_ORDER = [
  ...["ctrl", "alt", "shift", "win"].flatMap((key) => [key, `r${key}`]),
  "space",
  "esc",
];

const $ = (id) => document.getElementById(id);
let keyNames = KEY_NAMES.other;

const describeCombo = (combo) =>
  combo
    ? combo
        .split("+")
        .sort((a, b) => KEY_ORDER.indexOf(a) - KEY_ORDER.indexOf(b))
        .map((key) => keyNames[key] ?? key[0].toUpperCase() + key.slice(1))
        .join(" + ")
    : "None";

const showShortcuts = ({ pushToTalk, handsFree }) => {
  $("ptt").textContent = describeCombo(pushToTalk);
  $("handsfree").textContent = describeCombo(handsFree);
};

const showHotkeysReady = (ready) => {
  $("hotkeys-off").hidden = ready;
  $("change").disabled = !ready;
};

const note = (text, isError = false) => {
  $("shortcut-note").textContent = text;
  $("shortcut-note").classList.toggle("error", isError);
};

const showHistory = (entries) => {
  const list = $("history");
  list.replaceChildren(
    ...entries.map(({ text, at }) => {
      const item = document.createElement("li");
      const time = document.createElement("time");
      time.dateTime = new Date(at).toISOString();
      time.textContent = new Date(at).toLocaleString(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      });
      const body = document.createElement("div");
      body.className = "text";
      body.textContent = text;
      item.append(time, body);
      return item;
    }),
  );
  $("empty").hidden = entries.length > 0;
  $("clear").disabled = entries.length === 0;
};

$("change").addEventListener("click", async () => {
  $("change").disabled = true;
  note("Press and hold the new keys, then let go. Esc cancels.");
  const result = await window.dashboard.recordShortcut();
  $("change").disabled = false;
  if (result.saved) {
    showShortcuts(result);
    note("Saved.");
  } else if (result.cancelled) note("");
  else
    note(
      `${describeCombo(result.keys.join("+"))} can't be used. Use two or more of ` +
        `${["ctrl", "alt", "shift", "win"].map((key) => keyNames[key]).join(", ")}, ` +
        `or the right-hand ${["ctrl", "alt", "win"].map((key) => keyNames[key]).join(", ")} key alone.`,
      true,
    );
});

$("clear").addEventListener("click", () => window.dashboard.clearHistory());
$("open-accessibility").addEventListener("click", () =>
  window.dashboard.openAccessibility(),
);
window.dashboard.onHistory(showHistory);
window.dashboard.onHotkeysReady(showHotkeysReady);

window.dashboard.getState().then((state) => {
  keyNames = KEY_NAMES[state.platform] ?? KEY_NAMES.other;
  showShortcuts(state);
  showHotkeysReady(state.hotkeysReady);
  showHistory(state.history);
});
