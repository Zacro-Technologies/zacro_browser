'use strict';
// Explicit online acceptance; excluded from the normal offline unit/E2E suites.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'production Web Store acquisition runs version-pinned JSON Formatter in an isolated browser',
  { timeout: 90000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-live-store-'));
    const server = http.createServer((_req, res) => {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ message: 'Verified package runtime', values: [1, 2, 3] }));
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/example.json`;
    const env = { ...process.env, ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    delete env.ZACRO_SYNC_URL;
    const app = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    t.after(async () => {
      await app.close().catch(() => app.process().kill());
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const page = await app.firstWindow();
    await page.waitForFunction(() => !!window.zacro);
    const invoke = (action, payload = {}) =>
      page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    // A newly published version is held for explicit compatibility review.
    await app.evaluate(({ dialog }) => {
      dialog.showMessageBox = async (_window, options) => ({
        response:
          options.title === 'Review extension permissions' && options.message === 'JSON Formatter 0.10.2'
            ? 1
            : 0,
      });
    });
    const extension = await invoke('extension:install-store', {
      url: 'https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa',
    });
    assert.equal(extension.version, '0.10.2');
    assert.equal(extension.enabled, true);
    assert.equal(extension.publisherVerified, true);
    assert.equal(extension.source, 'chrome-web-store');
    await invoke('navigate', { url });
    const read = (expression) =>
      app.evaluate(
        ({ webContents }, { url, expression }) => {
          const wc = webContents.getAllWebContents().find((item) => item.getURL() === url);
          return wc ? wc.executeJavaScript(expression) : null;
        },
        { url, expression },
      );
    await expect
      .poll(() => read('document.querySelector("#jsonFormatterParsed")?.textContent'), { timeout: 15000 })
      .toContain('Verified package runtime');
    assert.equal(await read('typeof window.zacro'), 'undefined');
    assert.equal(await read('typeof window.zacroExtension'), 'undefined');
    await invoke('extension:options', { id: extension.id });
    await expect
      .poll(() =>
        app.evaluate(
          ({ BrowserWindow }, id) =>
            BrowserWindow.getAllWindows().some(
              (window) => window.webContents.getURL() === `chrome-extension://${id}/options/options.html`,
            ),
          extension.id,
        ),
      )
      .toBe(true);
    const state = await invoke('state:get');
    assert.match(state.extensions[0].iconData, /^data:image\/png;base64,/);
    t.diagnostic(
      'JSON Formatter0.10.2: real HTTPS download, production publisher verification, managed adaptation, native JSON formatting, options page and packaged icon passed. Native storage.local preferences remain local.',
    );
  },
);
