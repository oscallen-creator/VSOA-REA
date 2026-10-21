// IPC channel names shared by the main process and both renderer windows.
export const Channel = Object.freeze({
  // main -> recorder window
  RecorderCommand: "recorder:command",
  // recorder window -> main
  RecorderStarted: "recorder:started",
  RecorderChunk: "recorder:chunk",
  RecorderLevel: "recorder:level",
  RecorderDone: "recorder:done",
  RecorderError: "recorder:error",
  // main -> flow bar
  BarState: "bar:state",
  BarLevel: "bar:level",
  BarNotice: "bar:notice",
  // flow bar -> main
  BarClick: "bar:click",
  BarShapeReport: "bar:shape-report",
  BarHover: "bar:hover",
  BarContextMenu: "bar:context-menu",
});
