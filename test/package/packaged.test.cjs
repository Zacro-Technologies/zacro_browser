'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn, execFile } = require('node:child_process');
const { once } = require('node:events');
const { promisify } = require('node:util');
const { _electron, chromium, expect } = require('@playwright/test');
const { getCurrentFuseWire, FuseV1Options } = require('@electron/fuses');
const { makePDF } = require('../fixtures/pdf.cjs');
const { packagedPaths } = require('../../scripts/platform-build.cjs');
const execFileAsync = promisify(execFile);

test(
  'native package has hardened fuses, browses, parses PDFs and starts its isolated Codex runtime',
  { timeout: 90000, skip: !['win32', 'darwin'].includes(process.platform) },
  async (t) => {
    const root = path.resolve(__dirname, '../..');
    const captureMacDesktop = async (name) => {
      // Capture only the disposable CI desktop. The native traffic lights,
      // menu bar and sibling website views are outside a CDP shell screenshot.
      if (process.platform !== 'darwin' || process.env.CI !== 'true' || process.env.GITHUB_ACTIONS !== 'true')
        return;
      await execFileAsync('/usr/sbin/screencapture', ['-x', path.join(root, 'test-results', name)], {
        timeout: 5000,
      }).catch((error) => console.warn(`Optional native desktop capture unavailable: ${error.message}`));
    };
    const { executable, resources } = packagedPaths(root);
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
    const env = {
      ...process.env,
      ZACRO_USER_DATA: path.join(directory, 'packaged'),
      ZACRO_SYNC_DEV_LOOPBACK: '1',
    };
    delete env.ZACRO_SYNC_URL;
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
    const sync = await shell.evaluate(() => window.zacro.invoke('sync:status'));
    assert.equal(sync.state, 'setup-required');
    assert.equal(sync.account, null);
    await assert.rejects(
      shell.evaluate(() => window.zacro.invoke('sync:configure', { endpoint: 'http://127.0.0.1:4040' })),
      /HTTPS origin/,
      'a packaged build ignores the development-only plaintext setting',
    );
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
    await captureMacDesktop('packaged-mac-browser-desktop.png');
    await shell.evaluate(() => window.zacro.invoke('navigate', { url: 'zacro://newtab' }));
    await expect(shell.locator('#home-query')).toBeVisible();
    for (const theme of ['light', 'dark']) {
      await shell.evaluate((theme) => window.zacro.invoke('settings:update', { values: { theme } }), theme);
      await expect(shell.locator('html')).toHaveAttribute('data-theme', theme);
      await shell.emulateMedia({ reducedMotion: 'reduce' });
      await shell.screenshot({ path: path.join(root, `test-results/packaged-home-${theme}.png`) });
      await captureMacDesktop(`packaged-mac-home-${theme}-desktop.png`);
    }
    const exited = once(child, 'exit');
    await shell.evaluate(() => window.zacro.invoke('app:quit')).catch(() => {});
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
        modulePath: path.join(resources, 'app.asar/src/main/pdf.cjs'),
        pdf: document.toString('base64'),
      },
    );
    assert.match(parsed.text, /packaged PDF worker found this evidence/);
    assert.equal(parsed.totalPages, 1);
    const adapters = await harness.evaluate(
      async ({ app, safeStorage }, { asar, directory }) => {
        const requireModule = process
          .getBuiltinModule('module')
          .createRequire(app.getAppPath() + '/package.json');
        const fs = process.getBuiltinModule('fs');
        const path = process.getBuiltinModule('path');
        const { SyncStorage } = requireModule(path.join(asar, 'src/main/sync/storage.cjs'));
        const { CredentialVault } = requireModule(path.join(asar, 'src/main/sync/vault.cjs'));
        const BOOTSTRAP = 'zacro-compat-bootstrap.js';
        const { adaptExtension } = requireModule(path.join(asar, 'src/main/extensions/adapt.cjs'));
        // Requiring these exact packaged modules also resolves their shipped
        // archive/HTML dependencies, rather than borrowing checkout modules.
        requireModule(path.join(asar, 'src/main/extensions/host.cjs'));
        const local = path.join(directory, 'packaged-storage');
        const storage = new SyncStorage({ directory: local });
        storage.call('fixture', 'set', [{ packaged: true }]);
        storage.close();
        const reopened = new SyncStorage({ directory: local });
        const values = reopened.call('fixture', 'get', [null]);
        reopened.close();
        const vault = new CredentialVault({
          directory: local,
          protect: (text) => safeStorage.encryptString(text),
          unprotect: (bytes) => safeStorage.decryptString(bytes),
        });
        vault.assertAvailable();
        const source = path.join(directory, 'package-extension-source');
        const derived = path.join(directory, 'package-extension-derived');
        fs.mkdirSync(source);
        fs.writeFileSync(
          path.join(source, 'manifest.json'),
          JSON.stringify({
            manifest_version: 2,
            name: 'Package fixture',
            version: '1.0',
            background: { page: 'background.html', persistent: true },
          }),
        );
        fs.writeFileSync(
          path.join(source, 'background.html'),
          '<!doctype html><html><head><title>Packaged adapter</title></head><body></body></html>',
        );
        await adaptExtension(source, derived);
        return {
          values,
          bootstrap: fs.readFileSync(path.join(derived, BOOTSTRAP), 'utf8').length > 0,
          adapted: fs.readFileSync(path.join(derived, 'background.html'), 'utf8').includes(BOOTSTRAP),
          serverBundled: fs.existsSync(path.join(asar, 'services/sync/server.cjs')),
          testEntryBundled: fs.existsSync(path.join(asar, 'test/fixtures/extensions/sync-browser.cjs')),
        };
      },
      { asar: path.join(resources, 'app.asar'), directory },
    );
    assert.deepEqual(adapters, {
      values: { packaged: true },
      bootstrap: true,
      adapted: true,
      serverBundled: false,
      testEntryBundled: false,
    });
  },
);
