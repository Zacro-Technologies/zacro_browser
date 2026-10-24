'use strict';
// Reproducibly rasterize our own vector mark using the bundled Chromium engine.
const { app, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
app.enableSandbox();
app
  .whenReady()
  .then(async () => {
    const win = new BrowserWindow({
      show: false,
      webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false },
    });
    await win.loadURL('data:text/html,<html><body></body></html>');
    const svg = fs.readFileSync(path.join(__dirname, '../assets/icon.svg'), 'utf8');
    for (const size of [256, 512]) {
      const data = await win.webContents.executeJavaScript(
        `(async () => { const image = new Image(); image.src = ${JSON.stringify('data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64'))}; await image.decode(); const canvas = document.createElement('canvas'); canvas.width = canvas.height = ${size}; canvas.getContext('2d').drawImage(image,0,0,${size},${size}); return canvas.toDataURL('image/png').split(',')[1]; })()`,
      );
      const png = Buffer.from(data, 'base64');
      fs.writeFileSync(path.join(__dirname, `../assets/icon${size === 512 ? '' : '-256'}.png`), png);
      if (size === 256) {
        const header = Buffer.alloc(22);
        header.writeUInt16LE(1, 2);
        header.writeUInt16LE(1, 4);
        header.writeUInt16LE(1, 10);
        header.writeUInt16LE(32, 12);
        header.writeUInt32LE(png.length, 14);
        header.writeUInt32LE(22, 18);
        fs.writeFileSync(path.join(__dirname, '../assets/icon.ico'), Buffer.concat([header, png]));
      }
    }
    win.destroy();
    app.quit();
  })
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });
