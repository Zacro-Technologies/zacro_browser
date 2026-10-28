'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');
const { createInitialState } = require('../../src/core/store.cjs');

let server, base;
before(async () => {
  server = http.createServer((req, res) => {
    if (req.url === '/download') {
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': 'attachment; filename="archive-test.bin"',
        'Content-Length': '1000000',
      });
      res.write(Buffer.alloc(1000));
      const timer = setInterval(() => res.write(Buffer.alloc(1000)), 100);
      res.on('close', () => clearInterval(timer));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
    res.end(
      '<!doctype html><title>Archive fixture</title><button>Activate</button><input id="draft"><a href="/download" id="download">Download</a><h1>Today</h1>',
    );
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

const names = [
  'automatic archive closes clean loaded Today tabs, retains drafts and pins, and restores with a fresh timer',
  'automatic archive silently retains media, split panes, downloads, authentication openers and beforeunload vetoes',
  'selecting a tab during the isolated archive probe cancels its automatic close',
  'startup archives expired restored tabs while preserving the selected and recently viewed tabs',
];
for (const [index, name] of names.entries())
  test(name, { timeout: 35000 }, async (t) => {
    const root = path.resolve(__dirname, '../..');
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-archive-'));
    const profile = path.join(directory, 'profile');
    const resultPath = path.join(directory, 'result.json');
    await fs.mkdir(profile);
    if (index === 3) {
      const state = createInitialState();
      const now = Date.now();
      state.tabs = ['expired', 'recent', 'selected'].map((id) => ({
        id,
        profileId: 'default',
        spaceId: 'home',
        url: base + '/' + id,
        title: id,
        pinned: false,
        favorite: false,
        folderId: null,
        createdAt: now - 48 * 3600000,
        lastActiveAt: now - (id === 'recent' ? 1 : 24) * 3600000,
      }));
      state.activeTabId = 'selected';
      await fs.writeFile(path.join(profile, 'browser-state.json'), JSON.stringify(state));
    }
    let child;
    t.after(async () => {
      if (child && child.exitCode === null) child.kill();
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert.ok(path.basename(directory).startsWith('zacro-native-archive-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const env = {
      ...process.env,
      ZACRO_SKIP_ONBOARDING: '1',
      ZACRO_USER_DATA: profile,
      ZACRO_ARCHIVE_BASE: base,
      ZACRO_ARCHIVE_RESULT: resultPath,
      ZACRO_ARCHIVE_CASE: String(index),
    };
    delete env.ELECTRON_RUN_AS_NODE;
    child = spawn(require('electron'), [path.join(root, 'test/fixtures/auto-archive.cjs')], {
      cwd: root,
      env,
      windowsHide: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let diagnostics = '';
    child.stdout.on('data', (chunk) => (diagnostics = (diagnostics + chunk).slice(-5000)));
    child.stderr.on('data', (chunk) => (diagnostics = (diagnostics + chunk).slice(-5000)));
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    const result = JSON.parse(await fs.readFile(resultPath, 'utf8'));
    assert.equal(code, 0, result.error || diagnostics);
    assert.equal(result.passed, true);
  });
