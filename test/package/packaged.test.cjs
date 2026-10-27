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

async function bounded(promise, milliseconds, label) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${label} timed out after ${milliseconds}ms.`)),
          milliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function stopOwnedProcess(child) {
  if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, 'exit');
  child.kill('SIGKILL');
  await bounded(exited, 3000, `Stopping owned test process ${child.pid}`);
}

test(
  'native package has hardened fuses, browses, parses PDFs and starts its isolated Codex runtime',
  { timeout: 90000, skip: !['win32', 'darwin'].includes(process.platform) },
  async (t) => {
    const root = path.resolve(__dirname, '../..');
    let currentStage = 'package inspection';
    const stage = async (name, action, milliseconds = 15000) => {
      t.signal.throwIfAborted();
      currentStage = name;
      console.log(`[package] ${name}`);
      return bounded(Promise.resolve().then(action), milliseconds, name);
    };
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
    let child, browser, harness, harnessProcess;
    const server = http.createServer((_req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end(
        '<!doctype html><title>Packaged browser acceptance</title><h1>This page is rendered by the packaged Chromium browser.</h1>',
      );
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const abort = () => {
      console.error(`[package] Aborted during ${currentStage}; stopping owned processes.`);
      // An OS credential prompt can block Electron's main thread. Teardown must
      // not depend on that process handling another IPC or graceful-close call.
      if (child?.pid && child.exitCode === null) child.kill('SIGKILL');
      if (harnessProcess?.pid && harnessProcess.exitCode === null) harnessProcess.kill('SIGKILL');
    };
    t.signal.addEventListener('abort', abort, { once: true });
    t.after(
      async () => {
        const failures = [];
        const attempt = async (action) => {
          try {
            await action();
          } catch (error) {
            failures.push(error);
          }
        };
        console.log(`[package] Cleanup after ${currentStage}`);
        if (harness) {
          await attempt(() => bounded(harness.close(), 5000, 'Closing the PDF harness'));
          await attempt(() => stopOwnedProcess(harnessProcess));
        }
        // Kill our packaged child before waiting for a CDP disconnect. A hung
        // native thread must not prevent cleanup from ever reaching child.kill.
        await attempt(() => stopOwnedProcess(child));
        if (browser) await attempt(() => bounded(browser.close(), 3000, 'Disconnecting package CDP'));
        server.closeAllConnections();
        await attempt(() =>
          bounded(new Promise((resolve) => server.close(resolve)), 2000, 'Closing fixture server'),
        );
        assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
        assert(path.basename(directory).startsWith('zacro-package-'));
        await attempt(() =>
          fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }),
        );
        t.signal.removeEventListener('abort', abort);
        if (failures.length) throw new AggregateError(failures, 'Packaged test cleanup failed.');
      },
      { timeout: 20000 },
    );
    const env = {
      ...process.env,
      ZACRO_SKIP_ONBOARDING: '1',
      ZACRO_USER_DATA: path.join(directory, 'packaged'),
    };
    delete env.ELECTRON_RUN_AS_NODE;
    child = spawn(executable, ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0'], {
      env,
      windowsHide: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    child.stdout.resume();
    let diagnostics = '';
    const endpoint = await stage(
      'Native packaged startup',
      () =>
        new Promise((resolve, reject) => {
          child.on('error', (error) => {
            reject(error);
          });
          child.stderr.on('data', (data) => {
            diagnostics = (diagnostics + data).slice(-10000);
            const match = diagnostics.match(/DevTools listening on (ws:\/\/[^\s]+)/);
            if (match) {
              resolve(match[1]);
            }
          });
          child.once('exit', (code) => {
            reject(new Error(`Package exited before startup (${code}): ${diagnostics}`));
          });
        }),
    );
    browser = await stage('CDP connection', () => chromium.connectOverCDP(endpoint));
    const context = browser.contexts()[0];
    const shell = await stage('Packaged shell handshake', async () => {
      await expect
        .poll(() => context.pages().some((page) => page.url().includes('renderer/index.html')), {
          timeout: 10000,
        })
        .toBe(true);
      const page = context.pages().find((page) => page.url().includes('renderer/index.html'));
      await page.waitForFunction(() => Boolean(window.zacro));
      await expect(page.locator('#sidebar')).toBeVisible();
      const about = await page.evaluate(() => window.zacro.invoke('app:about'));
      assert.equal(about.packaged, true);
      assert.equal(about.name, 'Zacro');
      return page;
    });
    // No login and no model request: verify the shipped ASAR-unpacked native
    // runtime actually initializes from the hardened executable with its own home.
    await stage(
      'Isolated Codex handshake',
      async () => {
        const aiStatus = await shell.evaluate(() => window.zacro.invoke('ai:status'));
        assert.equal(aiStatus.available, true);
        assert.equal(aiStatus.configured, false);
        assert.equal(aiStatus.account, null);
        assert.equal(aiStatus.error, undefined);
      },
      30000,
    );
    const url = `http://127.0.0.1:${server.address().port}/`;
    await stage('Native page navigation', async () => {
      await shell.evaluate((url) => window.zacro.invoke('navigate', { url }), url);
      await expect
        .poll(async () => {
          const state = await shell.evaluate(() => window.zacro.invoke('state:get'));
          return state.tabs.find((tab) => tab.id === state.activeTabId)?.title;
        })
        .toBe('Packaged browser acceptance');
    });
    await fs.mkdir(path.join(root, 'test-results'), { recursive: true });
    await stage('Native browser capture', async () => {
      await shell.screenshot({ path: path.join(root, 'test-results/packaged-browser.png') });
      await captureMacDesktop('packaged-mac-browser-desktop.png');
    });
    await stage('Explicit home page', async () => {
      await shell.evaluate(() => window.zacro.invoke('tab:create', { homePage: true }));
      await expect(shell.locator('#home-query')).toBeVisible();
    });
    for (const theme of ['light', 'dark']) {
      await stage(`Native ${theme} home capture`, async () => {
        await shell.evaluate((theme) => window.zacro.invoke('settings:update', { values: { theme } }), theme);
        await expect(shell.locator('html')).toHaveAttribute('data-theme', theme);
        await shell.emulateMedia({ reducedMotion: 'reduce' });
        await shell.screenshot({ path: path.join(root, `test-results/packaged-home-${theme}.png`) });
        await captureMacDesktop(`packaged-mac-home-${theme}-desktop.png`);
      });
    }
    await stage(
      'Native packaged quit',
      async () => {
        const exited = once(child, 'exit');
        await shell.evaluate(() => window.zacro.invoke('app:quit')).catch(() => {});
        await exited;
      },
      10000,
    );
    await stage('Packaged CDP disconnect', () => browser.close(), 5000);
    browser = null;

    // The production binary deliberately disables main-process inspection. Load
    // its exact ASAR module in the same development runtime to verify its worker
    // and packaged fonts/dependencies without weakening those release fuses.
    harness = await stage(
      'Packaged PDF harness startup',
      () =>
        _electron.launch({
          args: [root],
          env: { ...env, ZACRO_SKIP_ONBOARDING: '1', ZACRO_USER_DATA: path.join(directory, 'harness') },
          timeout: 15000,
        }),
      20000,
    );
    harnessProcess = harness.process();
    await stage('PDF harness window', () => harness.firstWindow());
    const document = makePDF(['The packaged PDF worker found this evidence.']);
    const parsed = await stage('Packaged PDF worker', () =>
      harness.evaluate(
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
      ),
    );
    assert.match(parsed.text, /packaged PDF worker found this evidence/);
    assert.equal(parsed.totalPages, 1);
  },
);
