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
    const icns = [];
    const types = { 16: 'icp4', 32: 'icp5', 64: 'icp6', 128: 'ic07', 256: 'ic08', 512: 'ic09', 1024: 'ic10' };
    for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
      const data = await win.webContents.executeJavaScript(
        `(async () => { const image = new Image(); image.src = ${JSON.stringify('data:image/svg+xml;base64,' + Buffer.from(svg).toString('base64'))}; await image.decode(); const canvas = document.createElement('canvas'); canvas.width = canvas.height = ${size}; canvas.getContext('2d').drawImage(image,0,0,${size},${size}); return canvas.toDataURL('image/png').split(',')[1]; })()`,
      );
      const png = Buffer.from(data, 'base64');
      if (size === 256 || size === 512)
        fs.writeFileSync(path.join(__dirname, `../assets/icon${size === 512 ? '' : '-256'}.png`), png);
      const chunk = Buffer.alloc(8);
      chunk.write(types[size], 0, 4, 'ascii');
      chunk.writeUInt32BE(png.length + 8, 4);
      icns.push(chunk, png);
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
    const header = Buffer.alloc(8);
    header.write('icns', 0, 4, 'ascii');
    header.writeUInt32BE(8 + icns.reduce((length, chunk) => length + chunk.length, 0), 4);
    fs.writeFileSync(path.join(__dirname, '../assets/icon.icns'), Buffer.concat([header, ...icns]));
    win.destroy();
    app.quit();
  })
  .catch((error) => {
    console.error(error);
    app.exit(1);
  });
