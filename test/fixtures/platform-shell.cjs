'use strict';

// Render the real shell with a bounded fake host. This tests platform-specific
// DOM/keyboard contracts on every CI host; it is not a native macOS substitute.
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const { BrowserStore } = require('../../src/core/store.cjs');
app.enableSandbox();
app.setPath('userData', process.env.ZACRO_USER_DATA);
const store = new BrowserStore(process.env.ZACRO_USER_DATA);
let window;
const runtime = {
  fullScreen: false,
  focused: true,
  pages: {},
  defaultBrowser: { supported: true, configured: false },
};
const calls = [];
const snapshot = () => ({ ...store.snapshot(), runtime });
app.on('fixture:runtime', (_event, update) => {
  Object.assign(runtime, update);
  window.webContents.send('fixture:state', snapshot());
});
app.on('fixture:downloads', () => {
  const space = store.state.spaces.find((item) => item.id === store.state.activeSpaceId);
  store.state.downloads.push({
    id: 'test-download',
    profileId: space.profileId,
    name: 'Guide.pdf',
    state: 'completed',
    totalBytes: 1234,
  });
  window.webContents.send('fixture:state', snapshot());
});
app.fixtureCalls = calls;
ipcMain.handle('fixture:invoke', (_event, action, payload) => {
  calls.push({ action, payload });
  if (action === 'state:get') return snapshot();
  if (action === 'ai:status') return { configured: false };
  if (action === 'app:set-default-browser') {
    runtime.defaultBrowser.configured = true;
    return runtime.defaultBrowser;
  }
  if (['layout', 'ai:reset'].includes(action)) return null;
  if (action.startsWith('tab:') || action.startsWith('space:')) {
    const result = store.dispatch(action, payload);
    window.webContents.send('fixture:state', snapshot());
    return result;
  }
  return null;
});
app.whenReady().then(async () => {
  window = new BrowserWindow({
    width: 1100,
    height: 760,
    show: true,
    webPreferences: {
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'platform-preload.cjs'),
    },
  });
  await window.loadFile(path.resolve(__dirname, '../../src/renderer/index.html'));
});
app.on('window-all-closed', () => app.quit());
