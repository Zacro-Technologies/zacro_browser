'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const syncFs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const filename = path.resolve(__dirname, '../build/native-build.cjs');
const nativeRequire = createRequire(filename);
const source = nativeRequire('./native-source.cjs');
const branding = nativeRequire('../native-branding/apply.cjs');
const lock = nativeRequire('./native-build.lock.json');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-build-test-'));
  const state = {
    ready: true,
    sync: { schemaVersion: 1, attempt: 1 },
    managedCalls: 0,
    commands: [],
    sourceChecks: 0,
  };
  const args = { root, platform: 'win32-x64' };
  const layout = nativeRequire(filename).buildLayout(root, args.platform);
  const tools = {
    python: path.join(layout.depot, 'managed-python'),
    vpython: path.join(layout.depot, 'managed-vpython'),
  };
  const execute = async (program, argv) => {
    state.commands.push({ program, argv });
    if (program === 'git') return lock.depotToolsRevision;
    if (argv.some((value) => value.endsWith('autoninja.py'))) {
      await fs.writeFile(path.join(layout.out, 'chrome.exe'), 'FAKE TEST FIXTURE — never executable');
      if (state.driftDuringBuild) state.sync.attempt += 1;
    } else if (argv.includes('desc')) return 'chrome.exe\n';
    if (argv.includes('gen') && state.driftAfterGn) state.sourceChanged = true;
    return '';
  };
  const module = { exports: {} };
  vm.runInNewContext(syncFs.readFileSync(filename, 'utf8'), {
    module,
    exports: module.exports,
    __dirname: path.dirname(filename),
    Buffer,
    process: { ...process, platform: 'win32', arch: 'x64' },
    require(id) {
      if (id === './native-source.cjs') return { ...source, owner: async () => {}, execute };
      if (id === './native-preflight.cjs')
        return {
          nativePreflight: async () => ({
            sourceBuild: { ready: state.ready, blockers: ['fixture toolchain unavailable'] },
            tools: {},
          }),
        };
      if (id === './managed-tools.cjs')
        return {
          managedTools: async () => {
            state.managedCalls += 1;
            return tools;
          },
        };
      if (id === '../native-branding/apply.cjs')
        return {
          ...branding,
          apply: async () => ({ state: 'patched', patchSha256: branding.manifest.patch.sha256 }),
          inspect: async () => ({ state: 'patched', patchSha256: branding.manifest.patch.sha256 }),
        };
      if (id === './native-sync.cjs')
        return {
          verifySource: async () => {
            state.sourceChecks += 1;
            if (state.sourceChanged) throw new Error('fixture source changed');
          },
          verifySyncReceipt: async () => ({ receipt: structuredClone(state.sync), dependencyCount: 1 }),
        };
      if (id === 'node:child_process')
        return { spawn: () => assert.fail('No browser or compiler process may be launched in guard tests') };
      if (id === '../lib/artifacts.cjs')
        return {
          ...nativeRequire(id),
          writeStoredZip: async (destination) => {
            await fs.writeFile(destination, 'incomplete fixture archive');
            throw new Error('simulated archive failure');
          },
        };
      return nativeRequire(id);
    },
  });
  t.after(async () => {
    const real = await fs.realpath(root);
    assert.equal(path.dirname(real).toLowerCase(), (await fs.realpath(os.tmpdir())).toLowerCase());
    assert.ok(path.basename(real).startsWith('zacro-native-build-test-'));
    await fs.rm(real, { recursive: true, force: true });
  });
  return { api: module.exports, args, layout, state, tools };
}

test('unbuilt package and launch requests fail before managed tool or browser execution', async (t) => {
  const { api, args, state } = await fixture(t);
  await assert.rejects(api.packageBuild(args), /has not been built/);
  await assert.rejects(api.launch({ ...args, role: 'regular-a' }), /has not been built/);
  assert.equal(state.managedCalls, 0);
  assert.equal(state.commands.length, 0);
});

test('unavailable toolchain blocks configure and build without running source tools', async (t) => {
  const { api, args, state } = await fixture(t);
  state.ready = false;
  await assert.rejects(api.configure(args), /compilation is blocked/);
  await assert.rejects(api.build(args), /compilation is blocked/);
  assert.equal(state.managedCalls, 0);
  assert.equal(state.commands.length, 0);
});

test('new configuration invalidates the previous compiled receipt until another build', async (t) => {
  const { api, args, state } = await fixture(t);
  await api.configure(args);
  await api.build(args);
  assert.equal((await api.verifiedBuild(args)).receipt.compiled, true);
  state.sync.attempt = 2;
  await api.configure(args);
  await assert.rejects(api.verifiedBuild(args), /changed after this build/);
  await api.build(args);
  assert.equal((await api.verifiedBuild(args)).receipt.compiled, true);
});

test('changed output owner and GN arguments are retained and rejected', async (t) => {
  const { api, args, layout, state } = await fixture(t);
  await api.configure(args);
  const argumentsPath = path.join(layout.out, 'args.gn');
  await fs.appendFile(argumentsPath, '\nuser_custom_arg = true\n');
  const previous = state.commands.length;
  await assert.rejects(api.configure(args), /GN arguments were changed/);
  await assert.rejects(api.build(args), /configuration changed/);
  assert.match(await fs.readFile(argumentsPath, 'utf8'), /user_custom_arg/);
  assert.equal(state.commands.length, previous);
  await fs.writeFile(path.join(layout.out, '.zacro-native-output.json'), JSON.stringify({ kind: 'foreign' }));
  await assert.rejects(api.build(args), /ownership differs/);
});

test('source or dependency drift during native commands prevents success receipts', async (t) => {
  const { api, args, layout, state } = await fixture(t);
  state.driftAfterGn = true;
  await assert.rejects(api.configure(args), /source changed/);
  await assert.rejects(fs.access(layout.configured), { code: 'ENOENT' });
  state.sourceChanged = state.driftAfterGn = false;
  await api.configure(args);
  state.driftDuringBuild = true;
  await assert.rejects(api.build(args), /sync evidence changed/);
  await assert.rejects(fs.access(layout.built), { code: 'ENOENT' });
});

test('configuration-only receipt is never accepted as a compiled browser', async (t) => {
  const { api, args, layout, state } = await fixture(t);
  await api.configure(args);
  await fs.copyFile(layout.configured, layout.built);
  const previous = state.managedCalls;
  await assert.rejects(api.verifiedBuild(args), /build receipt does not identify/);
  assert.equal(state.managedCalls, previous);
});

test('failed archive creation removes only its staging file and publishes no output', async (t) => {
  const { api, args } = await fixture(t);
  await api.configure(args);
  await api.build(args);
  await assert.rejects(api.packageBuild(args), /simulated archive failure/);
  assert.deepEqual(await fs.readdir(path.join(args.root, 'native-output')), []);
});
