// Always-on bar: resting sliver, mic button on hover, waveform while recording,
// cancel/stop buttons in hands-free mode, spinner while processing.
// Reports its clickable rectangle so the rest of the transparent window stays click-through.

const BAR_COUNT = 10;
const SPINNER_SEGMENTS = 8;
const AUDIO_GAIN = 5;
const HOVER_LOCK_MS = 100;
const ERROR_RESET_MS = 500;
const READY_PAD_PX = 12;

const hot = document.getElementById("hot");
const pill = document.getElementById("pill");
const wave = pill.querySelector(".wave");
const spinner = pill.querySelector(".spinner");

for (let i = 0; i < BAR_COUNT; i++) {
  const bar = wave.appendChild(document.createElement("i"));
  const fromCenter = i - (BAR_COUNT - 1) / 2;
  bar.style.setProperty("--bulge", String(1 - fromCenter ** 2 / 48));
  // Delays 0..0.4 s then -0.5..-0.1 s, so the ripple travels across the bars.
  const delay = i < BAR_COUNT / 2 ? i * 0.1 : (i - BAR_COUNT) * 0.1;
  bar.style.animationDelay = `${delay.toFixed(1)}s`;
}
for (let i = 0; i < SPINNER_SEGMENTS; i++) {
  const segment = spinner.appendChild(document.createElement("i"));
  segment.style.transform = `rotate(${i * 45}deg) translateY(-6px)`;
  segment.style.animationDelay = `${((i - SPINNER_SEGMENTS) * 1.1) / SPINNER_SEGMENTS}s`;
}

let dictation = { status: "idle", isLocked: false };
let hovered = false;
let hoverTimer = null;
let errorUntil = 0;
let level = { target: 0, current: 0, frame: null };

const activeState = ({ status, isLocked }) => {
  if (status === "initializing" || status === "listening") {
    return isLocked ? "active-popo" : "active-ptt";
  }
  if (status === "stopping" || status === "processing") return "processing";
  return null;
};

const render = () => {
  const state =
    activeState(dictation) ??
    (Date.now() < errorUntil ? "error" : hovered ? "ready" : "resting");
  if (pill.dataset.state === state) return;
  pill.dataset.state = state;
  pill.setAttribute(
    "aria-label",
    state === "ready" ? "Start dictation" : "Stop dictation",
  );
  if (!state.startsWith("active")) {
    level.target = 0;
    delete pill.dataset.mic;
  }
  trackShapeDuringTransition();
};

let lastShapeKey = "";

/** Sends the clickable rectangle to the main process, only when it changed. */
const reportShape = () => {
  const pad = pill.dataset.state === "ready" ? READY_PAD_PX : 0;
  const rect = hot.getBoundingClientRect();
  const report = {
    rects: [
      {
        x: Math.round(rect.x - pad),
        y: Math.round(rect.y - pad),
        width: Math.round(rect.width + 2 * pad),
        height: Math.round(rect.height + 2 * pad),
      },
    ],
    shapeRects: [],
    viewport: { width: window.innerWidth, height: window.innerHeight },
  };
  const key = JSON.stringify(report);
  if (key === lastShapeKey) return;
  lastShapeKey = key;
  window.flowBar.reportShape(report);
};

/** Re-measures every frame while the 100 ms size transition runs. */
const trackShapeDuringTransition = () => {
  const until = performance.now() + 300;
  const step = () => {
    reportShape();
    if (performance.now() < until) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
};

const animateLevel = () => {
  level.current = Math.max(0, 0.85 * level.current + 0.15 * level.target);
  if (level.current < 0.01) level.current = 0;
  wave.style.setProperty(
    "--audio-scale",
    String(Math.max(1, AUDIO_GAIN * level.current)),
  );
  level.frame =
    level.current > 0 || level.target > 0
      ? requestAnimationFrame(animateLevel)
      : null;
};

window.flowBar.onState((state) => {
  dictation = state;
  render();
});

window.flowBar.onLevel((value) => {
  if (!pill.dataset.state.startsWith("active")) return;
  level.target = value;
  if (level.frame === null) level.frame = requestAnimationFrame(animateLevel);
});

window.flowBar.onMicActive((active) => {
  if (active) pill.dataset.mic = "active";
  else delete pill.dataset.mic;
});

window.flowBar.onNotice((notice) => {
  if (!notice.startsWith("error:")) return;
  errorUntil = Date.now() + ERROR_RESET_MS;
  render();
  setTimeout(render, ERROR_RESET_MS);
});

hot.addEventListener("mouseenter", () => {
  window.flowBar.hover(true);
  clearTimeout(hoverTimer);
  hoverTimer = setTimeout(() => {
    hovered = true;
    render();
  }, HOVER_LOCK_MS);
});

hot.addEventListener("mouseleave", () => {
  window.flowBar.hover(false);
  clearTimeout(hoverTimer);
  hoverTimer = setTimeout(() => {
    hovered = false;
    render();
  }, HOVER_LOCK_MS);
});

pill.addEventListener("click", (event) => {
  const state = pill.dataset.state;
  const button = event.target.closest("button");
  if (button?.classList.contains("cancel")) window.flowBar.cancel();
  else if (button?.classList.contains("stop") || state === "active-ptt")
    window.flowBar.stop();
  else if (state === "ready" || state === "resting") window.flowBar.start();
});

document.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  if (pill.dataset.state === "ready") window.flowBar.contextMenu();
});

new ResizeObserver(reportShape).observe(hot);
window.addEventListener("resize", reportShape);
reportShape();
