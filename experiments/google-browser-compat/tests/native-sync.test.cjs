'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const branding = require('../native-branding/apply.cjs');
const lock = require('../build/native-build.lock.json');
const {
  expectedConfiguration,
  validateSourceChanges,
  validateDependencyMap,
  validateSyncAgreement,
  validateSyncOutput,
  receiptMatches,
  verifySource,
  syncNative,
  verifySyncReceipt,
} = require('../build/native-sync.cjs');

const changedFiles = branding.manifest.files.map((file) => file.path).join('\0') + '\0';
const sourceDependency = { url: lock.sourceRepository, rev: lock.sourceRevision };
const dependencies = () => ({
  src: sourceDependency,
  'src/v8': { url: 'https://chromium.googlesource.com/v8/v8.git', rev: 'a'.repeat(40) },
  'src/third_party/node:infra/3pp/tools/nodejs/${platform}': {
    url: 'https://chrome-infra-packages.appspot.com/p/infra/3pp/tools/nodejs/windows-amd64/+/instance',
    rev: null,
  },
  'src/third_party/fixture:artifact-version/file.tar.xz': { url: 'gs://chromium-fixture/object', rev: null },
});
const syncOutput = () => ({
  solutions: {
    'src/': {
      revision: lock.sourceRevision,
      scm: 'git',
      url: lock.sourceRepository,
      was_processed: true,
      was_synced: true,
    },
    'src/v8/': { revision: 'a'.repeat(40), scm: 'git' },
    'src/third_party/node:infra/3pp/tools/nodejs/${platform}/': { revision: null, scm: 'cipd' },
  },
});

async function fixture(t, overrides = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-sync-test-'));
  const directory = path.join(root, 'native-source', lock.sourceVersion, 'win32-x64');
  const layout = {
    directory,
    depot: path.join(directory, 'depot_tools'),
    checkout: path.join(directory, 'chromium'),
    src: path.join(directory, 'chromium', 'src'),
    sourceRevision: lock.sourceRevision,
    depotRevision: lock.depotToolsRevision,
  };
  await fs.mkdir(path.join(layout.depot, '.cipd_bin'), { recursive: true });
  await fs.mkdir(layout.src, { recursive: true });
  await fs.writeFile(path.join(layout.checkout, '.gclient'), expectedConfiguration('win32-x64'));
  const tools = { vpython: path.join(layout.depot, '.cipd_bin', 'vpython3.exe') };
  await fs.writeFile(tools.vpython, 'test-only fake executable; never launched');
  const state = { patched: false, actual: dependencies(), synced: syncOutput(), ...overrides };
  const calls = [];
  t.mock.method(branding, 'inspect', async ({ source, requireRevision }) => {
    assert.equal(source, layout.src);
    assert.equal(requireRevision, false);
    if (state.inspectFailure) throw new Error('Source differs from both reviewed states');
    return {
      state: state.patched ? 'patched' : 'unpatched',
      patchSha256: branding.manifest.patch.sha256,
      files: branding.manifest.files.map((file) => ({
        path: file.path,
        sha256: state.patched ? file.afterSha256 : file.beforeSha256,
        state: state.patched ? 'patched' : 'unpatched',
      })),
    };
  });
  const execute = async (program, args, options = {}) => {
    calls.push({ program, args, options });
    if (program === 'git') {
      const target = args[1];
      if (args.includes('--show-toplevel')) return target;
      if (args.includes('HEAD'))
        return target === layout.src
          ? state.sourceHead || lock.sourceRevision
          : state.depotHead || lock.depotToolsRevision;
      if (args.includes('status')) return state.depotDirty || '';
      if (args.includes('--cached')) return state.staged || '';
      if (args.includes('diff'))
        return state.changed === undefined ? (state.patched ? changedFiles : '') : state.changed;
      throw new Error('Unexpected Git operation in test.');
    }
    assert.equal(program, tools.vpython);
    assert.equal(args[0], path.join(layout.depot, 'gclient.py'));
    assert.equal(options.cwd, layout.checkout);
    const output = args[args.indexOf('--output-json') + 1];
    assert.ok(path.isAbsolute(output));
    if (args[1] === 'sync') {
      assert.ok(args.includes('--nohooks'));
      assert.ok(args.includes('--no-history'));
      assert.ok(args.includes(`src@${lock.sourceRevision}`));
      if (state.syncFailure) throw new Error('simulated sync failure');
      await fs.writeFile(output, JSON.stringify(state.synced));
    } else {
      assert.equal(args[1], 'revinfo');
      assert.ok(args.includes('--actual'));
      if (state.revinfoFailure) throw new Error('simulated actual revision failure');
      await fs.writeFile(output, JSON.stringify(state.actual));
    }
    return '';
  };
  // Each fixture owns only this freshly created temporary directory. No recursive
  // shell operations or existing source/profile trees are involved.
  t.after(async () => {
    const real = await fs.realpath(root);
    assert.equal(path.dirname(real).toLowerCase(), (await fs.realpath(os.tmpdir())).toLowerCase());
    assert.ok(path.basename(real).startsWith('zacro-sync-test-'));
    await fs.rm(real, { recursive: true, force: true });
  });
  return { root, layout, tools, execute, platform: 'win32-x64', env: {}, state, calls };
}

test('source change gate requires the entire unstaged branding patch', () => {
  assert.deepEqual(validateSourceChanges({ state: 'unpatched' }), []);
  assert.equal(validateSourceChanges({ changed: changedFiles, state: 'patched' }).length, 9);
  assert.throws(() => validateSourceChanges({ staged: 'DEPS\0' }), /Staged/);
  assert.throws(() => validateSourceChanges({ changed: 'DEPS\0' }), /Unreviewed/);
  assert.throws(
    () => validateSourceChanges({ changed: 'chrome/app/theme/chromium/BRANDING\0', state: 'patched' }),
    /complete/,
  );
});

test('dependency validation preserves CIPD/GCS identities and null revisions', () => {
  assert.equal(Object.keys(validateDependencyMap(dependencies())).length, 4);
  assert.equal(validateSyncOutput(syncOutput()).solutions['src/'].revision, lock.sourceRevision);
  assert.throws(
    () => validateDependencyMap({ ...dependencies(), src: { ...sourceDependency, rev: 'b'.repeat(40) } }),
    /pinned/,
  );
  assert.throws(
    () => validateDependencyMap({ ...dependencies(), '../elsewhere': { url: null, rev: null } }),
    /Invalid/,
  );
  assert.throws(
    () => validateSyncOutput({ solutions: { 'src/': { revision: 'wrong', scm: 'git' } } }),
    /pinned/,
  );
});

test('actual Git revisions must agree with the successful sync output', () => {
  assert.doesNotThrow(() => validateSyncAgreement(syncOutput(), dependencies()));
  const changed = dependencies();
  changed['src/v8'].rev = 'b'.repeat(40);
  assert.throws(() => validateSyncAgreement(syncOutput(), changed), /differ from the successful sync/);
});

test('source verification accepts exact before/after state and checks actual hashes', async (t) => {
  const context = await fixture(t);
  assert.equal((await verifySource(context)).brandingState, 'unpatched');
  context.state.patched = true;
  assert.equal((await verifySource({ ...context, expectPatched: true })).brandingFiles.length, 9);
  await assert.rejects(verifySource({ ...context, expectPatched: false }), /must be unpatched/);
  context.state.inspectFailure = true;
  await assert.rejects(verifySource(context), /both reviewed states/);
});

test('source verification rejects wrong HEAD, depot changes and unreviewed edits before execution', async (t) => {
  const context = await fixture(t, { sourceHead: 'c'.repeat(40) });
  await assert.rejects(verifySource(context), /HEAD/);
  context.state.sourceHead = lock.sourceRevision;
  context.state.depotDirty = ' M gclient.py';
  await assert.rejects(verifySource(context), /Depot/);
  context.state.depotDirty = '';
  context.state.changed = 'DEPS\0';
  await assert.rejects(verifySource(context), /Unreviewed/);
  assert.ok(context.calls.every((call) => call.program === 'git'));
});

test('source verification rejects custom gclient configuration without running a tool', async (t) => {
  const context = await fixture(t);
  const filename = path.join(context.layout.checkout, '.gclient');
  await fs.appendFile(filename, 'custom_hooks = []\n');
  await assert.rejects(syncNative(context), /configuration differs/);
  assert.equal(context.calls.length, 0);
  assert.match(await fs.readFile(filename, 'utf8'), /custom_hooks/);
});

test('successful sync records and revalidates actual dependencies using managed vpython', async (t) => {
  const context = await fixture(t, { patched: true });
  const receipt = await syncNative(context);
  assert.equal(receipt.compiled, false);
  assert.equal(receipt.dependencyCount, 4);
  assert.equal(receipt.brandingPatchSha256, branding.manifest.patch.sha256);
  const result = await verifySyncReceipt({ ...context, expectPatched: true });
  assert.equal(result.dependenciesVerified, true);
  assert.equal(context.calls.filter((call) => call.args[1] === 'sync').length, 1);
  assert.equal(context.calls.filter((call) => call.args[1] === 'revinfo').length, 2);
});

test('failed sync and failed revinfo never produce a successful receipt', async (t) => {
  const context = await fixture(t, { syncFailure: true });
  await assert.rejects(syncNative(context), /simulated sync failure/);
  await assert.rejects(fs.access(path.join(context.layout.directory, 'sync.json')), { code: 'ENOENT' });
  context.state.syncFailure = false;
  context.state.revinfoFailure = true;
  await assert.rejects(syncNative(context), /actual revision failure/);
  await assert.rejects(fs.access(path.join(context.layout.directory, 'sync.json')), { code: 'ENOENT' });
});

test(
  'managed interpreter links stay within the depot directory',
  { skip: process.platform === 'win32' },
  async (t) => {
    const context = await fixture(t);
    const target = path.join(context.layout.depot, 'managed-vpython');
    await fs.rename(context.tools.vpython, target);
    await fs.symlink(target, context.tools.vpython);
    assert.equal((await syncNative(context)).compiled, false);
    await fs.unlink(context.tools.vpython);
    const outside = path.join(context.root, 'foreign-vpython');
    await fs.writeFile(outside, 'never executed');
    await fs.symlink(outside, context.tools.vpython);
    const before = context.calls.filter((call) => call.program !== 'git').length;
    await assert.rejects(syncNative(context), /outside/);
    assert.equal(context.calls.filter((call) => call.program !== 'git').length, before);
  },
);

test('receipt rejects dependency revision drift and preserves foreign dependency data', async (t) => {
  const context = await fixture(t);
  await syncNative(context);
  context.state.actual['src/v8'].rev = 'd'.repeat(40);
  await assert.rejects(verifySyncReceipt(context), /revisions changed/);
  assert.equal(context.state.actual['src/v8'].rev, 'd'.repeat(40));
  assert.ok(!context.calls.some((call) => call.args.includes('reset') || call.args.includes('--force')));
});

test('receipt rejects altered evidence and fails before fresh dependency commands', async (t) => {
  const context = await fixture(t);
  const receipt = await syncNative(context);
  await fs.appendFile(path.join(context.layout.directory, receipt.actualDependencies.path), ' ');
  const before = context.calls.filter((call) => call.args[1] === 'revinfo').length;
  await assert.rejects(verifySyncReceipt(context), /evidence has changed/);
  assert.equal(context.calls.filter((call) => call.args[1] === 'revinfo').length, before);
});

test('receipt paths and source binding cannot be redirected', async (t) => {
  const context = await fixture(t);
  const receipt = await syncNative(context);
  const proof = await verifySource(context);
  assert.throws(
    () => receiptMatches({ ...receipt, sourceRevision: '0'.repeat(40) }, proof),
    /does not match/,
  );
  assert.throws(
    () =>
      receiptMatches(
        { ...receipt, syncOutput: { ...receipt.syncOutput, path: '../../external.json' } },
        proof,
      ),
    /outside/,
  );
  assert.throws(
    () =>
      receiptMatches(
        {
          ...receipt,
          actualDependencies: {
            ...receipt.actualDependencies,
            path: `sync-evidence/${crypto.randomUUID()}/dependencies-actual.json`,
          },
        },
        proof,
      ),
    /outside/,
  );
});

test('unmanaged Python cannot run dependency sync', async (t) => {
  const context = await fixture(t);
  await assert.rejects(syncNative({ ...context, tools: { vpython: 'python.exe' } }), /managed depot/);
  assert.ok(context.calls.every((call) => call.program === 'git'));
});
