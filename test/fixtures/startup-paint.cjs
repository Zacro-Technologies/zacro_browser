'use strict';

// Run the real host without a debugger or Playwright's visibility switches.
// Those switches can make a hidden native page appear healthy in an E2E test.
const { app, BrowserWindow, webContents } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');

const resultPath = process.env.ZACRO_PAINT_RESULT;
if (!resultPath) throw new Error('This fixture requires an isolated result path.');
require('../../src/main/main.cjs');

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(read, description) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const value = await read();
    if (value) return value;
    await pause(25);
  }
  throw new Error(`Timed out waiting for ${description}`);
}
async function frame(contents, label) {
  let timer;
  try {
    return await Promise.race([
      contents.executeJavaScript(
        `new Promise(resolve => requestAnimationFrame(() => resolve({
          visibility: document.visibilityState,
          width: innerWidth,
          height: innerHeight,
          heading: document.querySelector('h1')?.textContent || '',
          draft: document.querySelector('input')?.value || ''
        })))`,
      ),
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${label}: no animation frame from the visible page`)),
          1500,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
async function inspect(contents, label, paint = true) {
  // Check before capturePage: capture itself can temporarily wake a hidden page.
  const state = await frame(contents, label);
  if (state.visibility !== 'visible') throw new Error(`${label}: renderer is ${state.visibility}`);
  if (!paint) return { label, ...state };
  const image = await contents.capturePage({}, { stayHidden: true });
  const size = image.getSize();
  const bitmap = image.toBitmap();
  const sample = (x, y) => {
    const px = Math.floor((x / state.width) * size.width);
    const py = Math.floor((y / state.height) * size.height);
    const offset = (py * size.width + px) * 4;
    // Native bitmap channel order varies by platform; these unique colors
    // remain distinguishable in either RGBA or BGRA order.
    return [...bitmap.subarray(offset, offset + 3)].sort((a, b) => a - b);
  };
  return {
    label,
    ...state,
    size,
    background: sample(state.width / 2, state.height / 2),
    marker: sample(45, 45),
  };
}

(async () => {
  const records = [];
  try {
    const url = process.argv.find((value) => /^http:\/\/127\.0\.0\.1:/.test(value));
    const window = await until(() => BrowserWindow.getAllWindows()[0], 'browser window');
    const shell = window.webContents;
    await until(
      () => shell.getURL().includes('/renderer/index.html') && !shell.isLoading(),
      'browser interface',
    );
    // A second interactive Zacro window can occlude this test window on Windows.
    // Establish the physical foreground precondition; do not disable Chromium's
    // normal visibility throttling or use capturePage to wake an occluded page.
    await until(() => window.isVisible(), 'shown browser window');
    window.moveTop();
    window.focus();
    await until(() => window.isFocused(), 'foreground browser window');
    const invoke = (action, payload = {}) =>
      shell.executeJavaScript(`window.zacro.invoke(${JSON.stringify(action)}, ${JSON.stringify(payload)})`);
    const first = await until(
      () =>
        webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === url && !contents.isLoading()),
      'initial destination',
    );
    records.push(await inspect(shell, 'shell-first-paint', false));
    records.push(await inspect(first, 'initial-page'));
    const initial = (await invoke('state:get')).activeTabId;
    await first.executeJavaScript(`document.querySelector('input').value = 'Retained draft'`);
    const other = await invoke('tab:create', { url: `${url}second` });
    const second = await until(
      () =>
        webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === `${url}second` && !contents.isLoading()),
      'second destination',
    );
    records.push(await inspect(second, 'new-tab'));
    await invoke('tab:activate', { id: initial });
    records.push(await inspect(first, 'restored-tab'));
    await invoke('peek:open', { url: `${url}preview` });
    const preview = await until(
      () =>
        webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === `${url}preview` && !contents.isLoading()),
      'preview destination',
    );
    records.push(await inspect(preview, 'new-preview'));
    await invoke('peek:close');
    records.push(await inspect(first, 'closed-preview'));
    await invoke('layout', { sidebarWidth: 230, panelWidth: 0, overlay: true });
    await pause(250);
    await invoke('layout', { sidebarWidth: 230, panelWidth: 0, overlay: false });
    records.push(await inspect(first, 'closed-overlay'));
    window.setContentSize(1000, 700);
    await until(() => first.mainFrame.visibilityState === 'visible', 'resized page');
    records.push(await inspect(first, 'resized-page'));
    records.push(await inspect(shell, 'resized-shell', false));
    await fs.writeFile(resultPath, JSON.stringify({ records }));
    app.exit(0);
  } catch (error) {
    await fs.writeFile(
      resultPath,
      JSON.stringify({
        records,
        error: error.stack || error.message,
        windows: BrowserWindow.getAllWindows().map((item) => ({
          id: item.id,
          visible: item.isVisible(),
          focused: item.isFocused(),
          url: item.webContents.getURL(),
          loading: item.webContents.isLoading(),
        })),
        pages: webContents
          .getAllWebContents()
          .map((item) => ({ id: item.id, url: item.getURL(), visibility: item.mainFrame.visibilityState })),
      }),
    );
    app.exit(1);
  }
})();
