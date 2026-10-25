'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');

test(
  'ordinary startup paints native pages and retains rendering after tab, overlay and resize changes',
  { timeout: 30000 },
  async (t) => {
    const root = path.resolve(__dirname, '../..');
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-paint-'));
    const resultPath = path.join(directory, 'paint.json');
    const server = http.createServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      response.end(`<!doctype html><title>Native first paint</title><style>
      html,body{margin:0;height:100%;background:rgb(31,121,93)}
      .marker{position:fixed;left:20px;top:20px;width:80px;height:80px;background:rgb(222,55,88)}
      input{position:fixed;top:120px;left:20px}h1{position:fixed;top:160px;left:20px;color:white}
      </style><div class="marker"></div><input aria-label="Retained draft"><h1>${request.url === '/second' ? 'Second page' : 'First page'}</h1>`);
    });
    let child;
    t.after(async () => {
      if (child && child.exitCode === null) child.kill();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
      assert(path.basename(directory).startsWith('zacro-paint-'));
      await fs.rm(directory, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/`;
    const env = {
      ...process.env,
      ZACRO_USER_DATA: path.join(directory, 'profile'),
      ZACRO_PAINT_RESULT: resultPath,
    };
    delete env.ELECTRON_RUN_AS_NODE;
    // No debugging port, inspector, automation driver, or rendering switches.
    child = spawn(require('electron'), [path.join(root, 'test/fixtures/startup-paint.cjs'), url], {
      cwd: root,
      env,
      // This is a visible GUI test. SW_HIDE can suppress Electron's first
      // ShowWindow on Windows and invalidate a native-paint assertion.
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
    assert.equal(code, 0, result.error ? JSON.stringify(result) : diagnostics);
    assert.equal(result.error, undefined);
    assert.equal(result.records.length, 9);
    for (const record of result.records) {
      assert.equal(record.visibility, 'visible', record.label);
      if (record.background) {
        // Native capture color conversion can round a channel by one level,
        // including in an unmodified Electron window on this display.
        for (const [kind, expected] of [
          ['background', [31, 93, 121]],
          ['marker', [55, 88, 222]],
        ]) {
          const actual = record[kind];
          assert.ok(
            actual.length === expected.length &&
              actual.every((channel, index) => Math.abs(channel - expected[index]) <= 1),
            `${record.label}: ${kind} expected ${expected} within one level; captured ${actual}`,
          );
        }
      }
    }
    assert.equal(result.records.find((record) => record.label === 'new-tab').heading, 'Second page');
    for (const label of ['restored-tab', 'closed-preview', 'closed-overlay', 'resized-page'])
      assert.equal(result.records.find((record) => record.label === label).draft, 'Retained draft', label);
  },
);
