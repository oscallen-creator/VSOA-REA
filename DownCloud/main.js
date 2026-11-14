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

  // Tall window shaped like the artwork (906 x 1735), so the first page fills it exactly; resizing keeps the shape.
  const ART = 906 / 1735;
  const height = Math.round(screen.getPrimaryDisplay().workAreaSize.height * 0.9);
  const win = new BrowserWindow({
    width: Math.round(height * ART), height, useContentSize: true, minWidth: 320, minHeight: Math.round(320 / ART), center: true,
    title: 'DownCloud', backgroundColor: '#faf2e7', autoHideMenuBar: true, show: false,
    webPreferences: { sandbox: true },
  });
  win.setAspectRatio(ART);
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
