// IPC channel names shared by the main process and the renderer windows.
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
  BarMicActive: "bar:mic-active",
  BarNotice: "bar:notice",
  // flow bar -> main
  BarStartClicked: "bar:start-clicked",
  BarStopClicked: "bar:stop-clicked",
  BarCancelClicked: "bar:cancel-clicked",
  BarShapeReport: "bar:shape-report",
  BarHover: "bar:hover",
  BarContextMenu: "bar:context-menu",
  // dashboard <-> main
  DashboardGetState: "dashboard:get-state",
  DashboardHistory: "dashboard:history",
  DashboardClearHistory: "dashboard:clear-history",
  DashboardRecordShortcut: "dashboard:record-shortcut",
  DashboardHotkeysReady: "dashboard:hotkeys-ready",
  DashboardOpenAccessibility: "dashboard:open-accessibility",
});
