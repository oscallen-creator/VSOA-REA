// Flow bar page: shows dictation state, a live level meter, and forwards clicks.
// It also reports the pill's on-screen rectangle so the main process can make
// everything else in this transparent window click-through.

const BAR_COUNT = 9;
const LEVEL_GAIN = 14;
const pill = document.getElementById("pill");
const meter = pill.querySelector(".meter");
const bars = Array.from({ length: BAR_COUNT }, () =>
  meter.appendChild(document.createElement("i")),
);
const history = Array.from({ length: BAR_COUNT }, () => 0);
let noticeTimer = null;

const reportShape = () => {
  const rect = pill.getBoundingClientRect();
  window.flowBar.reportShape({
    rects: [{ x: rect.x, y: rect.y, width: rect.width, height: rect.height }],
    shapeRects: [],
    viewport: { width: window.innerWidth, height: window.innerHeight },
  });
};

window.flowBar.onState(({ status, isLocked }) => {
  pill.dataset.status = status;
  pill.dataset.locked = String(isLocked);
  pill.setAttribute(
    "aria-label",
    status === "idle" ? "Start dictation" : "Stop dictation",
  );
  if (status !== "listening") history.fill(0);
});

window.flowBar.onLevel((rms) => {
  history.shift();
  history.push(Math.min(1, rms * LEVEL_GAIN));
  bars.forEach((bar, i) => {
    bar.style.height = `${3 + Math.round(history[i] * 15)}px`;
  });
});

window.flowBar.onNotice((notice) => {
  pill.dataset.notice = notice.split(":")[0];
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => delete pill.dataset.notice, 2000);
});

pill.addEventListener("click", () => window.flowBar.click());
pill.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  window.flowBar.contextMenu();
});
pill.addEventListener("mouseenter", () => window.flowBar.hover(true));
pill.addEventListener("mouseleave", () => window.flowBar.hover(false));
pill.addEventListener("transitionend", reportShape);
new ResizeObserver(reportShape).observe(pill);
window.addEventListener("resize", reportShape);
