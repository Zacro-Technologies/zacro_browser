'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const vm = require('node:vm');
const { spawnNativeMessagingFixture } = require('./helpers/native-messaging-fixture.cjs');
const {
  NativeMessagingBroker,
  createHostResolver,
  hostRegistrationPaths,
} = require('../src/main/extensions/native-messaging.cjs');
const ID = 'a'.repeat(32);
const ORIGIN = `chrome-extension://${ID}/`;
async function fixture(t, overrides = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const executable = path.join(dir, 'host');
  await fs.copyFile(path.join(__dirname, 'fixtures/native-messaging/host.cjs'), executable);
  await fs.chmod(executable, 0o700);
  const manifestPath = path.join(dir, 'com.zacro.test.json');
  const manifest = {
    name: 'com.zacro.test',
    description: 'Synthetic test host',
    type: 'stdio',
    path: executable,
    allowed_origins: [ORIGIN],
    ...overrides,
  };
  await fs.writeFile(manifestPath, JSON.stringify(manifest));
  const resolveHost = createHostResolver({ discoverPaths: () => [manifestPath] });
  return { dir, executable, manifestPath, manifest, resolveHost };
}
function context(overrides = {}) {
  return {
    profileId: 'p1',
    extensionId: ID,
    generation: 1,
    contextId: 'page1',
    permissions: ['nativeMessaging'],
    guard: () => true,
    ...overrides,
  };
}
function broker(t, resolveHost, options = {}) {
  const events = [];
  const broker = new NativeMessagingBroker({
    resolveHost,
    spawnHost: spawnNativeMessagingFixture,
    approveHost: async () => true,
    emit: (ctx, event) => events.push({ ctx, ...event }),
    ...options,
  });
  t.after(() => broker.dispose());
  return { broker, events };
}
async function until(predicate) {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return;
    await delay(10);
  }
  assert.fail('Native host event timed out');
}
for (const platform of ['darwin', 'win32'])
  test(`synthetic child reconstructs framed UTF-8 with ${platform} caller arguments`, async (t) => {
    const f = await fixture(t);
    let launchArgs;
    const { broker: b, events } = broker(t, f.resolveHost, {
      platform,
      spawnHost(executable, args, options) {
        launchArgs = args;
        assert.equal(options.shell, false);
        return spawnNativeMessagingFixture(executable, args, options);
      },
    });
    const ctx = context();
    await b.connect(ctx, 'com.zacro.test', 'port');
    b.post(ctx, 'port', { mode: 'fragmented', text: '日本語' });
    await until(() => events.some((e) => e.type === 'message'));
    assert.deepEqual(launchArgs, platform === 'win32' ? [ORIGIN, '--parent-window=0'] : [ORIGIN]);
    assert.deepEqual(events[0].message, { echo: '日本語', origin: ORIGIN });
    b.disconnect(ctx, 'port');
    assert.equal(events.at(-1).type, 'disconnect');
  });
test('port receives multiple messages and send returns the first response only', async (t) => {
  const f = await fixture(t);
  const { broker: b, events } = broker(t, f.resolveHost);
  const ctx = context();
  await b.connect(ctx, 'com.zacro.test', 'port');
  b.post(ctx, 'port', { mode: 'multiple' });
  await until(() => events.filter((e) => e.type === 'message').length === 2);
  assert.deepEqual(
    events.filter((e) => e.type === 'message').map((e) => e.message),
    [1, 2],
  );
  assert.equal(await b.send(ctx, 'com.zacro.test', { mode: 'multiple' }), 1);
});
for (const mode of ['length', 'json', 'utf8', 'truncated', 'exit', 'stderr'])
  test(`invalid host response ${mode} closes safely`, async (t) => {
    const f = await fixture(t);
    const { broker: b, events } = broker(t, f.resolveHost);
    const ctx = context();
    await b.connect(ctx, 'com.zacro.test', 'port');
    b.post(ctx, 'port', { mode });
    await until(() => events.some((e) => e.type === 'disconnect'));
    assert.match(events.at(-1).error, /Native/);
    assert.doesNotMatch(events.at(-1).error, /SECRET/);
    assert.throws(() => b.post(ctx, 'port', {}), /disconnected/);
  });
test('registration requires matching exact origin and strict manifest fields', async (t) => {
  for (const invalid of [
    { allowed_origins: ['chrome-extension://*/'] },
    { allowed_origins: [`chrome-extension://${'b'.repeat(32)}/`] },
    { name: 'different' },
    { type: 'shell' },
    { path: 'relative' },
    { path: 'https://example.com/host' },
  ]) {
    const f = await fixture(t, invalid);
    await assert.rejects(f.resolveHost('com.zacro.test', context()), /Native/);
  }
  const f = await fixture(t);
  for (const name of ['../host', 'https://host', '.a', 'a..b', 'UPPER', 'a.'])
    await assert.rejects(f.resolveHost(name, context()), /name/);
  await fs.writeFile(f.manifestPath, ' '.repeat(65537));
  await assert.rejects(f.resolveHost('com.zacro.test', context()), /manifest/);
});
test('local approval is mandatory and identity changes invalidate remembered approval', async (t) => {
  const f = await fixture(t);
  let approved = 0;
  const { broker: b } = broker(t, f.resolveHost, {
    approveHost: async (review) => {
      approved++;
      assert.equal(review.executablePath, await fs.realpath(f.executable));
      assert.match(review.identity, /^[a-f0-9]{64}$/);
      return approved === 1;
    },
  });
  const ctx = context();
  await b.connect(ctx, 'com.zacro.test', 'one');
  b.disconnect(ctx, 'one');
  await b.connect(ctx, 'com.zacro.test', 'two');
  b.disconnect(ctx, 'two');
  assert.equal(approved, 1);
  await fs.appendFile(f.executable, '\n// identity changed');
  await assert.rejects(b.connect(ctx, 'com.zacro.test', 'three'), /approval/);
  assert.equal(approved, 2);
});
test('approval cannot authorize a host changed during review', async (t) => {
  const f = await fixture(t);
  const { broker: b } = broker(t, f.resolveHost, {
    approveHost: async () => {
      await fs.appendFile(f.executable, '\n// swapped');
      return true;
    },
  });
  await assert.rejects(b.connect(context(), 'com.zacro.test', 'port'), /changed/);
});
test('permission, profile, generation and context identity cannot cross port boundaries', async (t) => {
  const f = await fixture(t);
  const { broker: b } = broker(t, f.resolveHost);
  const ctx = context();
  await assert.rejects(b.connect(context({ permissions: [] }), 'com.zacro.test', 'bad'), /permission/);
  await b.connect(ctx, 'com.zacro.test', 'port');
  for (const other of [
    context({ profileId: 'p2' }),
    context({ generation: 2 }),
    context({ contextId: 'other' }),
  ])
    assert.throws(() => b.post(other, 'port', {}), /disconnected/);
  b.revoke({ profileId: 'p1', extensionId: ID });
  assert.throws(() => b.post(ctx, 'port', {}), /disconnected/);
});
test('cancellation while approval is withheld never starts host and pending send times out', async (t) => {
  const f = await fixture(t);
  let release;
  const approval = new Promise((resolve) => (release = resolve));
  const controller = new AbortController();
  const { broker: b } = broker(t, f.resolveHost, { approveHost: () => approval, sendTimeoutMs: 40 });
  const connecting = b.connect(context({ signal: controller.signal }), 'com.zacro.test', 'port');
  controller.abort();
  release(true);
  await assert.rejects(connecting, /closed|cancel|revoked/);
  const { broker: other } = broker(t, f.resolveHost, { sendTimeoutMs: 40 });
  await assert.rejects(other.send(context(), 'com.zacro.test', { mode: 'hang' }), /timed out/);
});
test('dead guards and resource limits tear down queued input', async (t) => {
  const f = await fixture(t);
  let live = true;
  const ctx = context({ guard: () => live });
  const { broker: b, events } = broker(t, f.resolveHost, { maxPorts: 1, maxOutgoingBytes: 128 });
  await b.connect(ctx, 'com.zacro.test', 'one');
  await assert.rejects(b.connect(context({ contextId: 'second' }), 'com.zacro.test', 'two'), /limit/);
  assert.throws(() => b.post(ctx, 'one', 'x'.repeat(129)), /size/);
  live = false;
  assert.throws(() => b.post(ctx, 'one', {}), /revoked/);
  assert.equal(events.at(-1).type, 'disconnect');
});
test('registration paths follow the requested OS even with Windows path semantics', async () => {
  const sandboxModule = { exports: {} };
  vm.runInNewContext(
    await fs.readFile(path.join(__dirname, '../src/main/extensions/native-messaging.cjs'), 'utf8'),
    {
      module: sandboxModule,
      require: (name) => (name === 'node:path' ? path.win32 : require(name)),
      process,
      Buffer,
      TextDecoder,
      setTimeout,
      clearTimeout,
    },
  );
  const lookup = sandboxModule.exports.hostRegistrationPaths;
  assert.deepEqual(Array.from(lookup('com.zacro.test', { platform: 'darwin', home: '/u' })), [
    '/u/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.zacro.test.json',
    '/Library/Google/Chrome/NativeMessagingHosts/com.zacro.test.json',
  ]);
  assert.deepEqual(Array.from(lookup('com.zacro.test', { platform: 'linux', home: '/u' })), [
    '/u/.config/google-chrome/NativeMessagingHosts/com.zacro.test.json',
    '/etc/opt/chrome/native-messaging-hosts/com.zacro.test.json',
  ]);
});
test('OS lookup uses documented Chrome registration only and Windows 32-bit then 64-bit', async (t) => {
  assert.deepEqual(hostRegistrationPaths('com.zacro.test', { platform: 'darwin', home: '/u' }), [
    '/u/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.zacro.test.json',
    '/Library/Google/Chrome/NativeMessagingHosts/com.zacro.test.json',
  ]);
  assert.deepEqual(hostRegistrationPaths('com.zacro.test', { platform: 'linux', home: '/u' }), [
    '/u/.config/google-chrome/NativeMessagingHosts/com.zacro.test.json',
    '/etc/opt/chrome/native-messaging-hosts/com.zacro.test.json',
  ]);
  const calls = [];
  const resolve = createHostResolver({
    platform: 'win32',
    readRegistry: async (hive, view, key) => {
      calls.push([hive, view, key]);
      return null;
    },
  });
  await assert.rejects(resolve('com.zacro.test', context()), /not found/);
  assert.deepEqual(
    calls.map((c) => c.slice(0, 2)),
    [
      ['HKCU', 32],
      ['HKLM', 32],
      ['HKCU', 64],
      ['HKLM', 64],
    ],
  );
  assert.ok(calls.every((c) => c[2] === 'Software\\Google\\Chrome\\NativeMessagingHosts\\com.zacro.test'));
});

test('revocation interrupts a withheld approval without waiting for the reviewer', async (t) => {
  const f = await fixture(t);
  let entered;
  const reviewing = new Promise((resolve) => (entered = resolve));
  const { broker: b } = broker(t, f.resolveHost, {
    approveHost: () => {
      entered();
      return new Promise(() => {});
    },
  });
  const connecting = b.connect(context(), 'com.zacro.test', 'port');
  await reviewing;
  b.revoke({ profileId: 'p1' });
  await Promise.race([
    assert.rejects(connecting, /revoked/),
    delay(100).then(() => assert.fail('Revoked approval remained pending')),
  ]);
});
test('buffered messages during approval respect queue bounds and are discarded on denial', async (t) => {
  const f = await fixture(t);
  let enter, release;
  const entered = new Promise((resolve) => (enter = resolve));
  const approval = new Promise((resolve) => (release = resolve));
  const { broker: b, events } = broker(t, f.resolveHost, {
    approveHost: () => {
      enter();
      return approval;
    },
    maxQueueBytes: 32,
  });
  const ctx = context();
  const connecting = b.connect(ctx, 'com.zacro.test', 'port');
  await entered;
  b.post(ctx, 'port', { hello: 'a' });
  assert.throws(() => b.post(ctx, 'port', { hello: 'a'.repeat(20) }), /queue limit/);
  release(false);
  await assert.rejects(connecting, /queue|approval|revoked/);
  assert.equal(events.filter((event) => event.type === 'disconnect').length, 1);
});
test('Windows lookup stops at the first registered hive and view', async () => {
  const calls = [];
  const resolver = createHostResolver({
    platform: 'win32',
    readRegistry: async (hive, view) => {
      calls.push([hive, view]);
      return 'C:\\zacro-missing-fixture\\host.json';
    },
  });
  await assert.rejects(resolver('com.zacro.test', context()), /Native/);
  assert.deepEqual(calls, [['HKCU', 32]]);
});
test('revocation kills the real child and clears its live port', async (t) => {
  const f = await fixture(t);
  let child;
  const { broker: b } = broker(t, f.resolveHost, {
    spawnHost: (...args) => (child = spawnNativeMessagingFixture(...args)),
  });
  const ctx = context();
  await b.connect(ctx, 'com.zacro.test', 'port');
  b.post(ctx, 'port', { mode: 'hang' });
  b.revoke({ profileId: ctx.profileId, generation: ctx.generation });
  await until(() => child.exitCode !== null || child.signalCode !== null);
  assert.ok(child.killed);
  assert.equal(b.ports.size, 0);
});
test('a throwing generation guard revokes a live host without exposing guard details', async (t) => {
  const f = await fixture(t);
  let live = true;
  const ctx = context({
    guard: () => {
      if (!live) throw new Error('SECRET generation');
    },
  });
  const { broker: b, events } = broker(t, f.resolveHost);
  await b.connect(ctx, 'com.zacro.test', 'port');
  live = false;
  assert.throws(() => b.post(ctx, 'port', {}), /^Error: Native messaging context is revoked$/);
  assert.doesNotMatch(events.at(-1).error, /SECRET/);
});
test('denied approval never launches a child and a closed broker cannot reconnect', async (t) => {
  const f = await fixture(t);
  let spawned = false;
  const { broker: b } = broker(t, f.resolveHost, {
    approveHost: async () => false,
    spawnHost: () => {
      spawned = true;
      throw new Error('must never spawn');
    },
  });
  await assert.rejects(b.connect(context(), 'com.zacro.test', 'port'), /approval/);
  assert.equal(spawned, false);
  b.dispose();
  await assert.rejects(b.connect(context(), 'com.zacro.test', 'port2'), /closed/);
});
test('authenticated manager generation tokens may be strings', async (t) => {
  const f = await fixture(t);
  const { broker: b } = broker(t, f.resolveHost);
  const ctx = context({ generation: 'g-authenticated-uuid' });
  assert.deepEqual(await b.send(ctx, 'com.zacro.test', { ok: true }), { ok: true });
});
test('early cancellation is authenticated, scoped and consumed without resolving or spawning a host', async (t) => {
  let resolved = 0;
  const { broker: b } = broker(t, async () => {
    resolved++;
    throw new Error('Synthetic host must not be resolved');
  });
  const ctx = context();
  assert.throws(() => b.disconnect(context({ permissions: [] }), 'port'), /permission/);
  b.disconnect(ctx, 'port');
  for (const other of [
    context({ profileId: 'p2' }),
    context({ generation: 2 }),
    context({ contextId: 'other' }),
  ])
    await assert.rejects(b.connect(other, 'com.zacro.test', 'port'), /connection failed/);
  assert.equal(resolved, 3);
  await assert.rejects(b.connect(ctx, 'com.zacro.test', 'port'), /disconnected/);
  assert.equal(resolved, 3);
  assert.equal(b.ports.size, 0);
});
test('early cancellation bounds fail closed until the authenticated context is revoked', async (t) => {
  const { broker: b } = broker(t, async () => ({ identity: 'synthetic' }), {
    approveHost: async () => false,
  });
  const ctx = context();
  for (let i = 0; i < 257; i++) b.disconnect(ctx, `port-${i}`);
  await assert.rejects(b.connect(ctx, 'com.zacro.test', 'fresh'), /cancellation limit/);
  await assert.rejects(b.connect(context({ contextId: 'other' }), 'com.zacro.test', 'fresh'), /approval/);
  b.revoke(ctx);
  await assert.rejects(b.connect(ctx, 'com.zacro.test', 'fresh'), /approval/);
  b.disconnect(ctx, 'after-revoke');
  b.dispose();
  assert.equal(b.cancellations.size, 0);
});
