'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { _electron: electron, expect } = require('@playwright/test');

const root = path.resolve(__dirname, '../..');

test('adaptation rejects symlinks and leaves existing destinations untouched', async (t) => {
  const adaptPath = path.join(root, 'src/main/extensions/adapt.cjs');
  assert.equal(
    await fs.access(adaptPath).then(
      () => true,
      () => false,
    ),
    true,
  );
  const { adaptExtension } = require(adaptPath);
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-adapt-boundary-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const source = path.join(dir, 'source');
  await fs.mkdir(source);
  await fs.writeFile(
    path.join(source, 'manifest.json'),
    '{"manifest_version":3,"name":"fixture","version":"1"}',
  );
  await fs.symlink('/etc/hosts', path.join(source, 'escape'));
  await assert.rejects(adaptExtension(source, path.join(dir, 'derived')), /Unsupported package entry/);
  await fs.unlink(path.join(source, 'escape'));
  await fs.mkdir(path.join(dir, 'derived'));
  await fs.writeFile(path.join(dir, 'derived/marker'), 'keep');
  await assert.rejects(adaptExtension(source, path.join(dir, 'derived')), /EEXIST/);
  assert.equal(await fs.readFile(path.join(dir, 'derived/marker'), 'utf8'), 'keep');
});

test('adaptation preserves source and relative worker imports and is deterministic', async (t) => {
  const adaptPath = path.join(root, 'src/main/extensions/adapt.cjs');
  assert.equal(
    await fs.access(adaptPath).then(
      () => true,
      () => false,
    ),
    true,
    'adaptExtension is missing',
  );
  const { adaptExtension } = require(adaptPath);
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-adapt-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const source = path.join(dir, 'source');
  await fs.mkdir(path.join(source, 'background'), { recursive: true });
  const manifest = {
    manifest_version: 3,
    name: 'Original',
    version: '1.0',
    background: { service_worker: 'background/main.js', type: 'module' },
    content_scripts: [{ matches: ['https://example.com/*'], js: ['content.js'] }],
  };
  await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(manifest));
  await fs.writeFile(path.join(source, 'background/main.js'), "import './dependency.js';\n");
  await fs.writeFile(path.join(source, 'background/dependency.js'), 'globalThis.importSucceeded = true;');
  await fs.writeFile(path.join(source, 'content.js'), 'globalThis.originalContent = true;');
  const a = await adaptExtension(source, path.join(dir, 'a'));
  const b = await adaptExtension(source, path.join(dir, 'b'));
  assert.equal(a.transformVersion, b.transformVersion);
  assert.deepEqual(a.manifest, b.manifest);
  assert.equal(a.manifest.background.service_worker, 'background/main.js');
  assert.equal(
    await fs.readFile(path.join(source, 'background/main.js'), 'utf8'),
    "import './dependency.js';\n",
  );
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(source, 'manifest.json'), 'utf8')), manifest);
  assert.notEqual(a.manifest.content_scripts[0].js[0], 'content.js');
  for (const name of await fs.readdir(path.join(dir, 'a'), { recursive: true })) {
    if ((await fs.stat(path.join(dir, 'a', name))).isFile())
      assert.deepEqual(
        await fs.readFile(path.join(dir, 'a', name)),
        await fs.readFile(path.join(dir, 'b', name)),
      );
  }
});

// The focused MV2 command remains available; the normal suite includes every kind.
for (const kind of process.env.ZACRO_CONTEXT_MV2_PROBE === '1'
  ? ['mv2']
  : ['mv2', 'mv2-page', 'classic', 'module']) {
  test(
    `native ${kind} extension frame, background and isolated content script authenticate host round trips`,
    { timeout: 60000 },
    async (t) => {
      const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-context-'));
      const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory, ZACRO_CONTEXT_KIND: kind };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({
        args: [path.join(root, 'test/fixtures/extensions/context-host.cjs')],
        env,
      });
      let stderr = '';
      app.process().stderr.on('data', (chunk) => {
        stderr += chunk;
      });
      t.after(async () => {
        await app.close();
        await fs.rm(directory, { recursive: true, force: true });
      });
      await expect
        .poll(() => app.evaluate(() => globalThis.contextResult), {
          timeout: 20000,
          message: 'Fixture failed; inspect native diagnostics',
        })
        .toBeTruthy();
      const result = await app.evaluate(() => globalThis.contextResult);
      t.diagnostic(
        JSON.stringify(
          process.env.ZACRO_CONTEXT_VERBOSE === '1' || result.error
            ? { ...result, stderr }
            : {
                kind,
                electron: result.versions?.electron,
                calls: result.calls,
                disabledRejected: result.disabledRejected,
                unloadedRejected: result.unloadedRejected,
                lateRejected: result.lateRejected,
                invalidOriginRejected: result.invalidOriginRejected,
                wrongSessionRejected: result.wrongSessionRejected,
              },
        ),
      );
      assert.equal(result.error, undefined);
      assert.equal(result.profileId, 'profile-one');
      assert.match(result.extensionId, /^[a-p]{32}$/);
      for (const label of ['frame', 'background', 'content']) {
        assert.equal(
          result.calls[label]?.extensionId,
          result.extensionId,
          `${label}: native extension identity`,
        );
        assert.equal(result.calls[label]?.profileId, 'profile-one', `${label}: native session identity`);
        assert.equal(result.calls[label]?.nativeSender, true, `${label}: native sender is retained`);
      }
      assert.equal(result.calls.content.kind, 'content-script');
      assert.equal(result.pageBridge, 'undefined:undefined:undefined');
      assert.equal(result.ordinaryWorker, 'undefined:undefined:undefined');
      assert.equal(result.ordinaryServiceWorker, 'undefined:undefined:undefined');
      assert.equal(result.nativeMessaging, 'native-reply');
      assert.equal(result.nativePortMessaging, true);
      assert.equal(result.disabledRejected, true);
      assert.equal(result.disabledReuseRejected, true);
      assert.equal(result.forgedRejected, true);
      assert.equal(result.originalImport, true);
      assert.equal(result.unloadedRejected, true);
      assert.equal(result.staleContentRejected, true);
      assert.equal(result.invalidOriginRejected, true);
      assert.equal(result.wrongSessionRejected, true);
      assert.equal(result.lateRejected, true);
      assert.equal(result.brokerPreferences.sandbox, true);
      assert.equal(result.brokerPreferences.contextIsolation, true);
      assert.equal(result.brokerPreferences.nodeIntegration, false);
      assert.equal(result.brokerGlobal, 'undefined');
      assert.equal(result.leakedViewCapability, false);
      assert.equal(result.duplicateBrokerRejected, true);
      assert.equal(result.contentTrustedRejected, true);
      assert.equal(result.forgedContentRejected, true);
      assert.equal(result.backgroundCount, 1);
    },
  );
}
