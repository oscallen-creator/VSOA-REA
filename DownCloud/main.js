const { app, BrowserWindow, dialog, screen, session, shell } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

if (!app.requestSingleInstanceLock()) app.quit();

function uniquePath(dir, name) {
  const { name: base, ext } = path.parse(name);
  let p = path.join(dir, name);
  for (let i = 1; fs.existsSync(p); i++) p = path.join(dir, `${base} (${i})${ext}`);
  return p;
}

app.whenReady().then(async () => {
  process.env.FFMPEG_PATH = require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked');
  let port;
  try {
    port = await require('./server').start(Number(process.env.DOWNCLOUD_PORT) || 0);
  } catch (e) {
    dialog.showErrorBox('DownCloud', e.message);
    return app.quit();
  }
  const origin = `http://127.0.0.1:${port}`;

  // Quarter of the work area: half the width times half the height.
  const { width: w, height: h } = screen.getPrimaryDisplay().workAreaSize;
  const width = Math.round(w / 2), height = Math.round(h / 2);
  const win = new BrowserWindow({
    width, height, maxWidth: width, maxHeight: height, minWidth: 480, minHeight: 360, center: true,
    title: 'DownCloud', backgroundColor: '#111', autoHideMenuBar: true, show: false,
    webPreferences: { sandbox: true },
  });
  win.once('ready-to-show', () => win.show());

  const external = (url) => { if (/^https?:/.test(url)) shell.openExternal(url); };
  win.webContents.setWindowOpenHandler(({ url }) => { external(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => {
    if (new URL(url).origin !== origin) { e.preventDefault(); external(url); }
  });

  session.defaultSession.on('will-download', (_e, item) => {
    const file = uniquePath(app.getPath('downloads'), item.getFilename());
    item.setSavePath(file);
    item.once('done', (_ev, state) => { if (state === 'completed' && process.platform === 'darwin') app.dock.downloadFinished(file); });
  });

  win.loadURL(origin + '/');
});

app.on('window-all-closed', () => app.quit());
