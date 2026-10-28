'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
const { NativeMessagingBroker, createHostResolver } = require('../src/main/extensions/native-messaging.cjs');
const { spawnNativeMessagingFixture } = require('./helpers/native-messaging-fixture.cjs');
const ID = 'a'.repeat(32);
async function nativeFacade(t, { delayConnect = false } = {}) {
  let enter,
    release,
    deliver,
    spawned = 0;
  const reviewing = new Promise((resolve) => (enter = resolve));
  const approval = new Promise((resolve) => (release = resolve));
  const listeners = new Set();
  const nativeMessaging = new NativeMessagingBroker({
    resolveHost: async () => ({
      identity: 'synthetic',
      origin: `chrome-extension://${ID}/`,
      executablePath: '/synthetic/never-spawned',
    }),
    approveHost: () => {
      enter();
      return approval;
    },
    spawnHost: () => {
      spawned++;
      throw new Error('Synthetic spawn must never be reached');
    },
    emit: (_context, event) => {
      for (const listener of listeners) listener('runtime.nativePort', [event]);
    },
  });
  t.after(() => nativeMessaging.dispose());
  const api = new ExtensionAPI({
    resolveExtension: () => ({
      enabled: true,
      generation: 'g1',
      manifest: {},
      grants: { permissions: ['nativeMessaging'], origins: [] },
    }),
    nativeMessaging,
  });
  const context = {
    profileId: 'p1',
    extensionId: ID,
    generation: 'g1',
    contextId: 'lease:authenticated',
    kind: 'extension-frame',
  };
  const calls = [];
  const event = () => {
    const handlers = new Set();
    return {
      addListener: (fn) => handlers.add(fn),
      removeListener: (fn) => handlers.delete(fn),
      hasListener: (fn) => handlers.has(fn),
    };
  };
  const chrome = { runtime: { id: ID, onMessage: event(), onConnect: event() }, tabs: {}, storage: {} };
  vm.runInNewContext(await fs.readFile(path.join(__dirname, '../src/main/extensions/bootstrap.js'), 'utf8'), {
    chrome,
    document: { readyState: 'complete' },
    location: { protocol: 'chrome-extension:', pathname: '/page.html' },
    crypto: require('node:crypto').webcrypto,
    setTimeout,
    clearTimeout,
    console,
    zacroExtension: {
      onEvent: (listener) => listeners.add(listener),
      invoke(method, args) {
        const call = () => api.call(context, method, args);
        const result =
          delayConnect && method === 'runtime.connectNative'
            ? new Promise((resolve, reject) => {
                deliver = () => call().then(resolve, reject);
              })
            : call();
        calls.push(result);
        return result;
      },
    },
  });
  return {
    runtime: chrome.runtime,
    broker: nativeMessaging,
    reviewing,
    release,
    deliver: () => deliver(),
    calls,
    spawned: () => spawned,
  };
}
test('facade disconnect revokes held approval before a later approval can spawn a host', async (t) => {
  const f = await nativeFacade(t);
  const port = f.runtime.connectNative('com.zacro.test');
  let disconnected = 0;
  let settled = false;
  f.calls[0].then(
    () => (settled = true),
    () => (settled = true),
  );
  port.onDisconnect.addListener(() => disconnected++);
  await f.reviewing;
  try {
    assert.equal(f.broker.ports.size, 1);
    port.disconnect();
    await new Promise(setImmediate);
    assert.equal(f.broker.ports.size, 0, 'local disconnect must immediately revoke pending broker work');
    assert.equal(settled, true, 'pending connect must settle without waiting for approval');
  } finally {
    f.release(true);
    await Promise.allSettled(f.calls);
  }
  assert.equal(f.spawned(), 0);
  assert.equal(f.broker.ports.size, 0);
  assert.equal(f.broker.approvals.size, 0);
  assert.equal(disconnected, 0);
  assert.throws(() => port.postMessage({}), /disconnected/);
});
test('facade cancellation arriving before connect cannot be lost or launch a host', async (t) => {
  const f = await nativeFacade(t, { delayConnect: true });
  const port = f.runtime.connectNative('com.zacro.test');
  port.disconnect();
  await new Promise(setImmediate);
  f.release(true);
  f.deliver();
  await Promise.allSettled(f.calls);
  assert.equal(f.spawned(), 0);
  assert.equal(f.broker.ports.size, 0);
});
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
    spawnHost: spawnNativeMessagingFixture,
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

for (const pending of [false, true])
  test(`living native broker checks current permission during ${pending ? 'held approval' : 'inbound host event'}`, async (t) => {
    const { EventEmitter } = require('node:events');
    const { PassThrough } = require('node:stream');
    let approve, entered;
    const waiting = new Promise((resolve) => {
      entered = resolve;
    });
    const approval = new Promise((resolve) => {
      approve = resolve;
    });
    const child = new EventEmitter();
    Object.assign(child, {
      stdin: new PassThrough(),
      stdout: new PassThrough(),
      stderr: new PassThrough(),
      exitCode: null,
      signalCode: null,
      kill() {
        this.signalCode = 'SIGTERM';
      },
    });
    const events = [];
    const metadata = {
      enabled: true,
      generation: 'stable',
      manifest: {},
      grants: { permissions: ['nativeMessaging'], origins: [] },
    };
    let spawned = 0;
    const broker = new NativeMessagingBroker({
      resolveHost: async () => ({
        identity: 'test',
        origin: `chrome-extension://${ID}/`,
        executablePath: '/never-executed',
      }),
      approveHost: async () => {
        entered();
        return pending ? approval : true;
      },
      spawnHost: () => {
        spawned++;
        return child;
      },
      emit: (_ctx, event) => events.push(event),
    });
    t.after(() => {
      approve(true);
      broker.dispose();
    });
    const api = new ExtensionAPI({ resolveExtension: () => metadata, nativeMessaging: broker });
    const ctx = {
      profileId: 'p1',
      extensionId: ID,
      generation: 'stable',
      contextId: 'page',
      kind: 'extension-frame',
    };
    const connect = api.call(ctx, 'runtime.connectNative', ['com.zacro.test', 'port']);
    connect.catch(() => {});
    await waiting;
    if (!pending) await connect;
    metadata.grants = { permissions: [], origins: [] };
    if (pending) {
      approve(true);
      await assert.rejects(connect, /revoked/);
      assert.equal(spawned, 0);
    } else {
      const body = Buffer.from('{"afterRemoval":true}'),
        header = Buffer.alloc(4);
      header.writeUInt32LE(body.length);
      child.stdout.write(Buffer.concat([header, body]));
      assert.equal(
        events.some((event) => event.type === 'message'),
        false,
      );
      assert.equal(child.signalCode, 'SIGTERM');
    }
    assert.equal(broker.ports.size, 0);
  });

for (const pending of ['active', 'resolve', 'approval', 'cached'])
  test(`host removal immediately revokes ${pending} native connections across same-generation regrant`, async (t) => {
    const { EventEmitter } = require('node:events');
    const { PassThrough } = require('node:stream');
    const { ExtensionHost } = require('../src/main/extensions/host.cjs');
    let release, entered;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const waiting = new Promise((resolve) => {
      entered = resolve;
    });
    let hold = false;
    const children = [],
      events = [];
    const review = (ctx) => ({
      identity: 'registered-test',
      origin: `chrome-extension://${ctx.extensionId}/`,
      executablePath: '/never-executed',
    });
    const broker = new NativeMessagingBroker({
      resolveHost: async (_name, ctx) => {
        if (
          hold &&
          ctx.profileId === 'p1' &&
          ctx.extensionId === ID &&
          ['resolve', 'cached'].includes(pending)
        ) {
          entered();
          await gate;
        }
        return review(ctx);
      },
      approveHost: async (info) => {
        if (hold && info.profileId === 'p1' && info.extensionId === ID && pending === 'approval') {
          entered();
          await gate;
        }
        return true;
      },
      spawnHost: () => {
        const child = new EventEmitter();
        Object.assign(child, {
          stdin: new PassThrough(),
          stdout: new PassThrough(),
          exitCode: null,
          signalCode: null,
          kill() {
            this.signalCode = 'SIGTERM';
          },
        });
        children.push(child);
        return child;
      },
      emit: (ctx, event) => events.push({ profileId: ctx.profileId, extensionId: ctx.extensionId, ...event }),
    });
    t.after(() => {
      release();
      broker.dispose();
    });
    const metadata = {
      enabled: true,
      generation: 'stable',
      manifest: {},
      grants: { permissions: ['nativeMessaging'], origins: [] },
    };
    const api = new ExtensionAPI({ resolveExtension: () => metadata, nativeMessaging: broker });
    const context = {
      profileId: 'p1',
      extensionId: ID,
      generation: 'stable',
      contextId: 'caller',
      kind: 'extension-frame',
    };
    await api.call({ ...context, profileId: 'p2' }, 'runtime.connectNative', [
      'com.zacro.test',
      'foreign-profile',
    ]);
    await api.call({ ...context, extensionId: 'b'.repeat(32) }, 'runtime.connectNative', [
      'com.zacro.test',
      'foreign-extension',
    ]);
    if (pending === 'cached') {
      await api.call(context, 'runtime.connectNative', ['com.zacro.test', 'old']);
      await api.call(context, 'runtime.disconnectNative', ['old']);
    }
    hold = true;
    const connect = api.call(context, 'runtime.connectNative', ['com.zacro.test', 'removed']);
    connect.catch(() => {});
    if (pending === 'active') await connect;
    else await waiting;
    const host = Object.assign(Object.create(ExtensionHost.prototype), { nativeMessaging: broker });
    metadata.grants = { permissions: [], origins: [] };
    host.permissionsChanged('p1', ID, {
      before: { permissions: ['nativeMessaging'] },
      after: metadata.grants,
    });
    metadata.grants = { permissions: ['nativeMessaging'], origins: [] };
    assert.equal(broker.ports.size, 2, 'revocation must precede another native event or resolver completion');
    assert.equal(children[0].signalCode, null);
    assert.equal(children[1].signalCode, null);
    const spawnedBefore = children.length;
    release();
    if (pending !== 'active') await assert.rejects(connect, /revoked/);
    assert.equal(children.length, spawnedBefore);
    assert.equal(
      events.filter((event) => event.portId === 'removed' && event.type === 'disconnect').length,
      1,
    );
  });
