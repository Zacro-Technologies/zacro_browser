'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { spawn } = require('node:child_process');

let server, base;
before(async () => {
  const favicon = await fs.readFile(path.resolve(__dirname, '../../assets/icon-256.png'));
  server = http.createServer((req, res) => {
    if (req.url === '/favicon.png') {
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
      res.end(favicon);
      return;
    }
    if (req.url === '/favicon.ico') {
      res.writeHead(404);
      res.end();
      return;
    }
    if (req.url === '/download') {
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': 'attachment; filename="pin-test.bin"',
        'Content-Length': '1000000',
      });
      res.write(Buffer.alloc(1000));
      const timer = setInterval(() => res.write(Buffer.alloc(1000)), 100);
      res.on('close', () => clearInterval(timer));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' });
    res.end(
      `<!doctype html><title>Favorite fixture</title>${req.url.startsWith('/no-icon') ? '' : '<link rel="icon" href="/favicon.png" type="image/png">'}<button id="activate">Activate</button><input id="draft"><a id="download" href="/download">Download</a><h1>Retained favorite</h1>`,
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
  'pinned Close honors beforeunload, retains metadata and wakes a fresh native page',
  'idle sleeping obeys Never/timeout and preserves active and dirty pages',
  'split/media/download protection and silent beforeunload veto keep pages alive',
  'trusted shadow-root editing protects the pin without sharing form values',
  'retained favorite icons stay bound to their tab/profile/URL and clear with browsing data',
];
for (const [index, name] of names.entries())
  test(name, { timeout: 30000 }, async (t) => {
    const root = path.resolve(__dirname, '../..');
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-pins-'));
    const resultPath = path.join(directory, 'result.json');
    let child;
    t.after(async () => {
      if (child && child.exitCode === null) child.kill();
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert.ok(path.basename(directory).startsWith('zacro-native-pins-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    const env = {
      ...process.env,
      ZACRO_USER_DATA: path.join(directory, 'profile'),
      ZACRO_PIN_BASE: base,
      ZACRO_PIN_RESULT: resultPath,
      ZACRO_PIN_CASE: String(index),
    };
    delete env.ELECTRON_RUN_AS_NODE;
    child = spawn(require('electron'), [path.join(root, 'test/fixtures/pinned-lifecycle.cjs')], {
      cwd: root,
      env,
      windowsHide: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let diagnostics = '';
    child.stdout.on('data', (chunk) => {
      diagnostics = (diagnostics + chunk).slice(-5000);
    });
    child.stderr.on('data', (chunk) => {
      diagnostics = (diagnostics + chunk).slice(-5000);
    });
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    const result = JSON.parse(await fs.readFile(resultPath, 'utf8'));
    assert.equal(code, 0, result.error || diagnostics);
    assert.equal(result.passed, true);
  });
