'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
for (const kind of ['classic', 'module'])
  test(
    `managed native ${kind} worker accepts a package-root resource and retains relative imports`,
    { timeout: 30000 },
    async (t) => {
      const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-root-worker-'));
      const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory, ZACRO_WORKER_KIND: kind };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({
        ...(process.env.ZACRO_CUSTOM_ELECTRON ? { executablePath: process.env.ZACRO_CUSTOM_ELECTRON } : {}),
        args: [path.resolve(__dirname, '../fixtures/extensions/worker-resource-host.cjs')],
        env,
      });
      t.after(async () => {
        await app.close();
        await fs.rm(directory, { recursive: true, force: true });
      });
      await expect
        .poll(() => app.evaluate(() => globalThis.workerResourceResult), { timeout: 20000 })
        .toBeTruthy();
      const result = await app.evaluate(() => globalThis.workerResourceResult);
      t.diagnostic(JSON.stringify(result));
      assert.equal(result.error, undefined);
      assert.equal(result.enabled, true);
      assert.equal(result.nativePath, '/js/background.js');
      assert.equal(result.derivedPath, '/js/background.js');
      assert.equal(result.sourceUnchanged, true);
      assert.equal(result.managedOriginalUnchanged, true);
      assert.equal(result.probe.id, result.id);
      assert.equal(result.probe.kind, 'service-worker');
      assert.equal(result.probe.nativeSender, true);
      assert.deepEqual(result.probe.args, [
        'genuine-relative-dependency',
        true,
        `chrome-extension://${result.id}/js/background.js`,
        '/js/background.js',
      ]);
    },
  );
