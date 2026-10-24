'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
const { createInteractiveSite } = require('../fixtures/interactive-site.cjs');

test(
  'repeated browsing, Peek and split cycles release native pages and preserve working state',
  { timeout: 240000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-soak-'));
    const site = createInteractiveSite();
    await new Promise((resolve) => site.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${site.address().port}`;
    const env = { ...process.env, ZACRO_USER_DATA: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const browser = await electron.launch({ args: [path.resolve(__dirname, '../..')], env });
    const child = browser.process();
    t.after(async () => {
      let timer;
      try {
        await Promise.race([
          browser.close(),
          new Promise((_resolve, reject) => {
            timer = setTimeout(() => reject(new Error('Browser shutdown exceeded five seconds')), 5000);
          }),
        ]);
      } catch (error) {
        child.kill();
        throw error;
      } finally {
        clearTimeout(timer);
        site.closeAllConnections();
        await new Promise((resolve) => site.close(resolve));
        const target = path.resolve(directory);
        if (
          path.dirname(target) === path.resolve(os.tmpdir()) &&
          path.basename(target).startsWith('zacro-soak-')
        )
          await fs.rm(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      }
    });
    const page = await browser.firstWindow();
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.waitForFunction(() => Boolean(window.zacro));
    const invoke = (action, payload = {}) =>
      page.evaluate(([action, payload]) => window.zacro.invoke(action, payload), [action, payload]);
    await invoke('navigate', { url: base + '/' });
    const initial = await invoke('state:get');
    const firstId = initial.activeTabId;
    await expect.poll(async () => (await invoke('state:get')).runtime.page.loading).toBe(false);
    await browser.evaluate(async ({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((w) => w.getURL() === url);
      await contents.executeJavaScript(
        "document.querySelector('#draft').value='Keep this draft throughout the soak'; window.scrollTo(0,300)",
      );
    }, base + '/');
    const samples = [];
    const durations = [];
    const cycles = Math.max(10, Math.min(300, Number(process.env.ZACRO_SOAK_CYCLES) || 40));
    for (let cycle = 0; cycle < cycles; cycle++) {
      const start = performance.now();
      const tab = await invoke('tab:create', { url: `${base}/notes?cycle=${cycle}` });
      await expect
        .poll(async () => {
          const snapshot = await invoke('state:get');
          return snapshot.activeTabId === tab.id && !snapshot.runtime.page.loading;
        })
        .toBe(true);
      await invoke('split:toggle', { id: firstId });
      await invoke('peek:open', { url: `${base}/notes?preview=${cycle}` });
      await expect
        .poll(async () => {
          const preview = (await invoke('state:get')).runtime.peek;
          return preview && !preview.loading;
        })
        .toBe(true);
      await invoke('peek:close');
      await invoke('split:toggle');
      await invoke('tab:close', { id: tab.id });
      await invoke('tab:activate', { id: firstId });
      await expect
        .poll(() =>
          browser.evaluate(
            ({ webContents }) =>
              webContents.getAllWebContents().filter((w) => /^http:\/\/127\.0\.0\.1:/.test(w.getURL()))
                .length,
          ),
        )
        .toBe(1);
      durations.push(performance.now() - start);
      if (cycle % 5 === 0 || cycle === cycles - 1) {
        samples.push(
          await browser.evaluate(({ app, webContents }, cycle) => {
            const processes = app.getAppMetrics().map((process) => ({
              type: process.type,
              memoryKiB: process.memory?.privateBytes || process.memory?.workingSetSize || 0,
            }));
            return {
              cycle: cycle + 1,
              contents: webContents.getAllWebContents().length,
              memoryKiB: processes.reduce((total, process) => total + process.memoryKiB, 0),
              processes,
            };
          }, cycle),
        );
      }
    }
    const preserved = await browser.evaluate(async ({ webContents }, url) => {
      const contents = webContents.getAllWebContents().find((w) => w.getURL() === url);
      return contents.executeJavaScript(
        "({draft:document.querySelector('#draft').value,scroll:window.scrollY})",
      );
    }, base + '/');
    assert.equal(preserved.draft, 'Keep this draft throughout the soak');
    assert.ok(preserved.scroll > 200, 'The original reading position survives repeated operations');
    assert.deepEqual(errors, []);
    assert.ok(
      samples.every((sample) => sample.contents === 2),
      'Only the shell and retained page remain after each cycle',
    );
    const sorted = [...durations].sort((a, b) => a - b);
    const result = {
      recordedAt: new Date().toISOString(),
      cycles,
      samples,
      cycleMedianMs: Math.round(sorted[Math.floor(cycles / 2)]),
      cycleP95Ms: Math.round(sorted[Math.floor(cycles * 0.95)]),
      note: 'Local deterministic resource-lifecycle soak; memory samples are observations, not a cross-machine performance guarantee.',
    };
    await fs.mkdir('test-results', { recursive: true });
    await fs.writeFile('test-results/soak.json', JSON.stringify(result, null, 2));
    t.diagnostic(JSON.stringify(result));
  },
);
