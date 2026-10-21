// Dictation state machine, following Wispr Flow's action handlers:
// - hold-to-talk starts on press; releasing after the debounce window stops and processes;
// - a release inside the window waits one more window for a second press, else dismisses (accidental tap);
// - a second press inside the window locks hands-free mode; a third dismisses;
// - hands-free toggle or a click on the bar starts locked, and a later press/click stops;
// - nothing new starts while the previous transcript is still processing.

import {
  DICTATION_DEBOUNCE_DELAY_MS,
  DICTATION_DURATION_TIMEOUT_MS,
  DICTATION_DURATION_WARNING_MS,
  NO_AUDIO_DISMISS_MS,
} from "../constants.js";

export const Status = Object.freeze({
  Idle: "idle",
  Initializing: "initializing",
  Listening: "listening",
  Stopping: "stopping",
  Processing: "processing",
});

export const Source = Object.freeze({ Keyboard: "keyboard", Bar: "bar" });

const ACTIVE = new Set([Status.Initializing, Status.Listening]);
const BUSY = new Set([Status.Stopping, Status.Processing]);

export class DictationController {
  #recorder;
  #process;
  #onChange;
  #onNotice;
  #now;
  #timers;
  status = Status.Idle;
  isLocked = false;
  startTime = 0;
  #tapTimer = null;
  #limitTimers = [];
  #session = 0;

  /**
   * @param {object} deps
   * @param {{start(): Promise<void>, stop(): Promise<Uint8Array>, cancel(): Promise<void>}} deps.recorder
   * @param {(pcm: Uint8Array) => Promise<void>} deps.process transcribe, clean up and paste one recording
   * @param {(state: {status: string, isLocked: boolean}) => void} deps.onChange
   * @param {(notice: string) => void} [deps.onNotice]
   */
  constructor({
    recorder,
    process,
    onChange,
    onNotice = () => {},
    now = Date.now,
    timers = { setTimeout, clearTimeout },
  }) {
    this.#recorder = recorder;
    this.#process = process;
    this.#onChange = onChange;
    this.#onNotice = onNotice;
    this.#now = now;
    this.#timers = timers;
  }

  get isActive() {
    return ACTIVE.has(this.status);
  }

  pushToTalkDown() {
    if (this.#rejectWhileBusy()) return;
    if (!this.isActive) return void this.#start(false);
    if (this.#elapsed() < DICTATION_DEBOUNCE_DELAY_MS) {
      if (this.isLocked) return void this.dismiss("triple_press");
      this.#clearTapTimer();
      this.#setLocked(true);
      return;
    }
    if (this.isLocked) void this.stop("re_press");
  }

  pushToTalkUp() {
    if (!this.isActive || this.isLocked) return;
    if (this.#elapsed() < DICTATION_DEBOUNCE_DELAY_MS) {
      this.#armTapTimer();
    } else if (this.status === Status.Initializing) {
      this.dismiss("released_before_ready");
    } else {
      void this.stop("key_release");
    }
  }

  /** Hands-free toggle; also what a click on the always-on bar does. */
  toggleHandsFree(source = Source.Keyboard) {
    if (this.#rejectWhileBusy()) return;
    if (this.isActive && (this.isLocked || source === Source.Bar)) {
      if (this.isLocked && this.#elapsed() < DICTATION_DEBOUNCE_DELAY_MS) {
        return void this.dismiss("double_press");
      }
      return void this.stop(source === Source.Bar ? "stop_button" : "re_press");
    }
    if (!this.isActive) void this.#start(true);
    else this.#setLocked(true);
  }

  dismiss(reason) {
    if (!this.isActive) return;
    this.#endSession();
    this.#emitNotice(`dismissed:${reason}`);
    void this.#recorder.cancel().catch(() => {});
  }

  async stop(reason) {
    if (!this.isActive) return;
    const session = this.#session;
    this.#clearTapTimer();
    this.#clearLimitTimers();
    this.#setStatus(Status.Stopping);
    try {
      const pcm = await this.#recorder.stop();
      if (session !== this.#session) return;
      this.#setStatus(Status.Processing);
      await this.#process(pcm, { reason });
    } catch (error) {
      this.#emitNotice(
        `error:${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      if (session === this.#session) this.#endSession();
    }
  }

  async #start(locked) {
    const session = ++this.#session;
    this.startTime = this.#now();
    this.isLocked = locked;
    this.#setStatus(Status.Initializing);
    this.#armLimitTimers(session);
    try {
      await this.#recorder.start();
      if (session === this.#session && this.status === Status.Initializing) {
        this.#setStatus(Status.Listening);
      }
    } catch (error) {
      if (session !== this.#session) return;
      this.#emitNotice(
        `error:${error instanceof Error ? error.message : String(error)}`,
      );
      this.#endSession();
    }
  }

  #rejectWhileBusy() {
    if (!BUSY.has(this.status)) return false;
    this.#emitNotice("busy:previous_transcript_processing");
    return true;
  }

  #armTapTimer() {
    this.#clearTapTimer();
    this.#tapTimer = this.#timers.setTimeout(() => {
      this.#tapTimer = null;
      if (this.isActive && !this.isLocked) this.dismiss("accidental_tap");
    }, DICTATION_DEBOUNCE_DELAY_MS);
  }

  #clearTapTimer() {
    if (this.#tapTimer !== null) this.#timers.clearTimeout(this.#tapTimer);
    this.#tapTimer = null;
  }

  #armLimitTimers(session) {
    this.#clearLimitTimers();
    this.#limitTimers = [
      this.#timers.setTimeout(() => {
        const silent = this.#recorder.receivedAudio?.() === false;
        if (session === this.#session && this.isActive && silent)
          this.dismiss("no_audio");
      }, NO_AUDIO_DISMISS_MS),
      this.#timers.setTimeout(() => {
        if (session === this.#session && this.isActive)
          this.#emitNotice("warning:one_minute_left");
      }, DICTATION_DURATION_WARNING_MS),
      this.#timers.setTimeout(() => {
        if (session === this.#session) void this.stop("duration_limit");
      }, DICTATION_DURATION_TIMEOUT_MS),
    ];
  }

  #clearLimitTimers() {
    for (const timer of this.#limitTimers) this.#timers.clearTimeout(timer);
    this.#limitTimers = [];
  }

  #endSession() {
    this.#session++;
    this.#clearTapTimer();
    this.#clearLimitTimers();
    this.isLocked = false;
    this.#setStatus(Status.Idle);
  }

  #elapsed() {
    return this.#now() - this.startTime;
  }

  #setLocked(locked) {
    this.isLocked = locked;
    this.#emitChange();
  }

  #setStatus(status) {
    this.status = status;
    this.#emitChange();
  }

  #emitChange() {
    this.#onChange({ status: this.status, isLocked: this.isLocked });
  }

  #emitNotice(notice) {
    this.#onNotice(notice);
  }
}
