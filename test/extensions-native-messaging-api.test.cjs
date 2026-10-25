'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
const { NativeMessagingBroker, createHostResolver } = require('../src/main/extensions/native-messaging.cjs');
const ID = 'a'.repeat(32);
test('native API sends through the verified broker and rejects content and undeclared permissions', async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-api-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const executable = path.join(dir, 'host');
  await fs.copyFile(path.join(__dirname, 'fixtures/native-messaging/host.cjs'), executable);
  await fs.chmod(executable, 0o700);
  const manifestPath = path.join(dir, 'com.zacro.test.json');
  await fs.writeFile(
    manifestPath,
    JSON.stringify({
      name: 'com.zacro.test',
      description: 'Synthetic fixture',
      type: 'stdio',
      path: executable,
      allowed_origins: [`chrome-extension://${ID}/`],
    }),
  );
  const nativeMessaging = new NativeMessagingBroker({
    resolveHost: createHostResolver({ discoverPaths: () => [manifestPath] }),
    approveHost: async () => true,
  });
  t.after(() => nativeMessaging.dispose());
  const metadata = {
    enabled: true,
    generation: 'g1',
    manifest: {},
    grants: { permissions: ['nativeMessaging'], origins: [] },
  };
  const api = new ExtensionAPI({ resolveExtension: () => metadata, nativeMessaging });
  const ctx = {
    profileId: 'p1',
    extensionId: ID,
    generation: 'g1',
    contextId: 'lease:host-authenticated',
    kind: 'extension-frame',
    assertCurrent: () => {},
  };
  assert.deepEqual(
    await api.call(ctx, 'runtime.sendNativeMessage', ['com.zacro.test', { hello: 'native' }]),
    { hello: 'native' },
  );
  await assert.rejects(
    api.call({ ...ctx, kind: 'content-script' }, 'runtime.sendNativeMessage', ['com.zacro.test', {}]),
    /Trusted/,
  );
  metadata.grants.permissions = [];
  await assert.rejects(api.call(ctx, 'runtime.sendNativeMessage', ['com.zacro.test', {}]), /permission/);
});
test('production local review shows exact canonical identity and rejects stale profile or generation', async () => {
  const { ExtensionHost } = require('../src/main/extensions/host.cjs');
  let active = 'p1',
    generation = 'g1',
    response = 1;
  const shown = [];
  const review = {
    profileId: 'p1',
    extensionId: ID,
    generation: 'g1',
    name: 'com.zacro.test',
    registeredManifestPath: '/registration/host.json',
    manifestPath: '/canonical/host.json',
    manifestSha256: '1'.repeat(64),
    registeredExecutablePath: '/registration/host',
    executablePath: '/canonical/host',
    executableSha256: '2'.repeat(64),
  };
  const host = Object.assign(Object.create(ExtensionHost.prototype), {
    closed: false,
    getProfile: (id) => ({ id, name: 'Local profile' }),
    activeProfile: () => ({ id: active }),
    manager: {
      resolveExtension: () => ({
        enabled: true,
        generation,
        manifest: { name: 'Reviewed extension' },
        grants: { permissions: ['nativeMessaging'] },
      }),
    },
    getWindow: () => undefined,
    native: {
      dialog: {
        showMessageBox: async (_window, options) => {
          shown.push(options);
          return { response };
        },
      },
    },
  });
  assert.equal(await host.approveNativeHost(review), true);
  assert.match(shown[0].detail, /\/canonical\/host/);
  assert.match(shown[0].detail, new RegExp(review.executableSha256));
  assert.equal(shown[0].defaultId, 0);
  assert.equal(shown[0].cancelId, 0);
  response = 0;
  assert.equal(await host.approveNativeHost(review), false);
  active = 'p2';
  assert.equal(await host.approveNativeHost(review), false);
  assert.equal(shown.length, 2);
  active = 'p1';
  generation = 'g2';
  assert.equal(await host.approveNativeHost(review), false);
  assert.equal(shown.length, 2);
  generation = 'g1';
  host.native.dialog.showMessageBox = async () => {
    active = 'p2';
    return { response: 1 };
  };
  assert.equal(await host.approveNativeHost(review), false);
});
