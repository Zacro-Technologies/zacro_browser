'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { _electron, chromium, expect } = require('@playwright/test');
const { getCurrentFuseWire, FuseV1Options } = require('@electron/fuses');
const { makePDF } = require('../fixtures/pdf.cjs');

test(
  'Windows package has hardened fuses, browses, parses PDFs and starts its isolated Codex runtime',
  { timeout: 90000, skip: process.platform !== 'win32' },
  async (t) => {
    const root = path.resolve(__dirname, '../..');
    const executable = path.join(root, 'dist/win-unpacked/Zacro.exe');
    await fs.access(executable);
    const fuses = await getCurrentFuseWire(executable);
    for (const fuse of ['RunAsNode', 'EnableNodeOptionsEnvironmentVariable', 'EnableNodeCliInspectArguments'])
      assert.equal(fuses[FuseV1Options[fuse]], 48, fuse);
    for (const fuse of [
      'EnableCookieEncryption',
      'EnableEmbeddedAsarIntegrityValidation',
      'OnlyLoadAppFromAsar',
    ])
      assert.equal(fuses[FuseV1Options[fuse]], 49, fuse);
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-package-'));
    let child, browser, harness;
    const server = http.createServer((_req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end(
        '<!doctype html><title>Packaged browser acceptance</title><h1>This page is rendered by the packaged Chromium browser.</h1>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(async () => {
      if (harness) await harness.close().catch(() => harness.process().kill());
      if (browser) await browser.close().catch(() => {});
      if (child && child.exitCode === null) child.kill();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const env = { ...process.env, ZACRO_USER_DATA: path.join(directory, 'packaged') };
    delete env.ELECTRON_RUN_AS_NODE;
    child = spawn(executable, ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'], {
      env,
      windowsHide: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let diagnostics = '';
    const endpoint = await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`Packaged startup timed out: ${diagnostics.slice(-2000)}`)),
        15000,
      );
      child.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.stderr.on('data', (data) => {
        diagnostics = (diagnostics + data).slice(-10000);
        const match = diagnostics.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
        }
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`Package exited before startup (${code}): ${diagnostics}`));
      });
    });
    browser = await chromium.connectOverCDP(endpoint);
    const context = browser.contexts()[0];
    await expect
      .poll(() => context.pages().some((page) => page.url().includes('renderer/index.html')), {
        timeout: 10000,
      })
      .toBe(true);
    const shell = context.pages().find((page) => page.url().includes('renderer/index.html'));
    await shell.waitForFunction(() => Boolean(window.zacro));
    await expect(shell.locator('#sidebar')).toBeVisible();
    const about = await shell.evaluate(() => window.zacro.invoke('app:about'));
    assert.equal(about.packaged, true);
    assert.equal(about.name, 'Zacro');
    // No login and no model request: verify the shipped ASAR-unpacked native
    // runtime actually initializes from the hardened executable with its own home.
    const aiStatus = await shell.evaluate(() => window.zacro.invoke('ai:status'));
    assert.equal(aiStatus.available, true);
    assert.equal(aiStatus.configured, false);
    assert.equal(aiStatus.account, null);
    assert.equal(aiStatus.error, undefined);
    const url = `http://127.0.0.1:${server.address().port}/`;
    await shell.evaluate((url) => window.zacro.invoke('navigate', { url }), url);
    await expect
      .poll(async () => {
        const state = await shell.evaluate(() => window.zacro.invoke('state:get'));
        return state.tabs.find((tab) => tab.id === state.activeTabId)?.title;
      })
      .toBe('Packaged browser acceptance');
    await fs.mkdir(path.join(root, 'test-results'), { recursive: true });
    await shell.screenshot({ path: path.join(root, 'test-results/packaged-browser.png') });
    await shell.evaluate(() => window.zacro.invoke('navigate', { url: 'zacro://newtab' }));
    await expect(shell.locator('#home-query')).toBeVisible();
    for (const theme of ['light', 'dark']) {
      await shell.evaluate((theme) => window.zacro.invoke('settings:update', { values: { theme } }), theme);
      await expect(shell.locator('html')).toHaveAttribute('data-theme', theme);
      await shell.emulateMedia({ reducedMotion: 'reduce' });
      await shell.screenshot({ path: path.join(root, `test-results/packaged-home-${theme}.png`) });
    }
    const exited = once(child, 'exit');
    await shell.evaluate(() => window.zacro.invoke('window:close')).catch(() => {});
    await Promise.race([
      exited,
      new Promise((_, reject) => {
        const timer = setTimeout(() => reject(new Error('Packaged browser did not close.')), 10000);
        timer.unref();
      }),
    ]);
    await browser.close();
    browser = null;

    // The production binary deliberately disables main-process inspection. Load
    // its exact ASAR module in the same development runtime to verify its worker
    // and packaged fonts/dependencies without weakening those release fuses.
    harness = await _electron.launch({
      args: [root],
      env: { ...env, ZACRO_USER_DATA: path.join(directory, 'harness') },
    });
    await harness.firstWindow();
    const document = makePDF(['The packaged PDF worker found this evidence.']);
    const parsed = await harness.evaluate(
      async ({ app }, data) => {
        const requireModule = process
          .getBuiltinModule('module')
          .createRequire(app.getAppPath() + '/package.json');
        const { extractPDF } = requireModule(data.modulePath);
        return extractPDF(process.getBuiltinModule('buffer').Buffer.from(data.pdf, 'base64'));
      },
      {
        modulePath: path.join(root, 'dist/win-unpacked/resources/app.asar/src/main/pdf.cjs'),
        pdf: document.toString('base64'),
      },
    );
    assert.match(parsed.text, /packaged PDF worker found this evidence/);
    assert.equal(parsed.totalPages, 1);
  },
);
