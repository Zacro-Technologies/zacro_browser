'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  parseOptions,
  sourceLayout,
  sourceEnvironment,
  gclientConfiguration,
  owner,
  pinnedCheckout,
  execute,
  assertNativeOperation,
  main,
} = require('../build/native-source.cjs');
const { ensureRoot } = require('../lib/paths.cjs');
const lock = require('../build/native-build.lock.json');

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-source-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    const parent = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), parent.toLowerCase());
    assert.match(path.basename(real), /^zacro-native-source-test-/);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}

test('native source CLI excludes browser/account input and unsupported targets', () => {
  assert.equal(parseOptions(['prepare', '--platform', 'win32-x64']).platform, 'win32-x64');
  for (const values of [
    [],
    ['launch'],
    ['prepare', '--url', 'https://accounts.google.com'],
    ['sync', '--platform', 'linux-x64'],
    ['status', '--root', 'a', '--root', 'b'],
    ['prepare', '--root'],
  ])
    assert.throws(() => parseOptions(values));
});

test('native source pins remain independent from the earlier snapshot experiment', () => {
  assert.equal(lock.sourceVersion, '156.0.8078.48');
  assert.equal(lock.sourceRevision, 'd0c02bfad08ec92a6ffcf989e53cd995e6381a4c');
  assert.notEqual(lock.sourceRevision, require('../engines.lock.json').engines.chromium.sourceRevision);
  const layout = sourceLayout(path.resolve(os.tmpdir(), 'owned'), 'darwin-arm64');
  assert.ok(layout.src.includes(lock.sourceVersion));
  assert.ok(layout.src.includes('darwin-arm64'));
  assert.match(gclientConfiguration('darwin-arm64'), /target_os = \['mac'\]/);
  assert.match(gclientConfiguration('win32-x64'), /target_os = \['win'\]/);
  assert.match(gclientConfiguration('win32-x64'), /'managed': False/);
});

test('native source environment pins depot tools and removes browser credential/logging overrides', () => {
  const result = sourceEnvironment('owned-depot', {
    Path: 'original-path',
    GOOGLE_API_KEY: 'fixture',
    SSLKEYLOGFILE: 'fixture',
    NODE_OPTIONS: 'fixture',
    OTHER: 'preserved',
  });
  assert.equal(result.Path, `owned-depot${path.delimiter}original-path`);
  assert.equal(result.DEPOT_TOOLS_UPDATE, '0');
  assert.equal(result.DEPOT_TOOLS_WIN_TOOLCHAIN, '0');
  assert.equal(result.GIT_TERMINAL_PROMPT, '0');
  for (const key of ['GOOGLE_API_KEY', 'SSLKEYLOGFILE', 'NODE_OPTIONS']) assert.equal(result[key], undefined);
  assert.equal(result.OTHER, 'preserved');
});

test('environment aliases cannot bypass managed settings or inject Git configuration', () => {
  const result = sourceEnvironment('owned-depot', {
    Path: 'original',
    PATH: 'untrusted',
    depot_tools_update: '1',
    git_config_count: '1',
    GIT_CONFIG_KEY_0: 'url.bad.insteadOf',
    GIT_CONFIG_VALUE_0: 'https://',
    cipd_cache_dir: 'elsewhere',
    vpython_bypass: 'bypass',
    PYTHONPATH: 'elsewhere',
  });
  assert.equal(Object.keys(result).filter((key) => key.toLowerCase() === 'path').length, 1);
  assert.equal(result.DEPOT_TOOLS_UPDATE, '0');
  assert.equal(result.depot_tools_update, undefined);
  assert.equal(result.GIT_CONFIG_COUNT, '2');
  assert.equal(result.GIT_CONFIG_KEY_0, 'core.autocrlf');
  assert.equal(result.GIT_CONFIG_VALUE_0, 'false');
  assert.equal(result.git_config_count, undefined);
  assert.equal(result.vpython_bypass, undefined);
  assert.equal(result.cipd_cache_dir, undefined);
});

test('prepare and sync reject foreign hosts before creating files, while status permits inspection', async (t) => {
  for (const command of ['prepare', 'sync'])
    assert.throws(
      () => assertNativeOperation({ command, platform: 'darwin-arm64' }, 'win32-x64'),
      /native OS/,
    );
  assert.doesNotThrow(() =>
    assertNativeOperation({ command: 'status', platform: 'darwin-arm64' }, 'win32-x64'),
  );
  const root = path.join(await scratch(t), 'not-created');
  const foreign = process.platform === 'win32' ? 'darwin-arm64' : 'win32-x64';
  await assert.rejects(main(['prepare', '--root', root, '--platform', foreign]), /native OS/);
  await assert.rejects(fs.access(root), { code: 'ENOENT' });
});

test('source ownership rejects foreign data, changed revisions and escaped source paths', async (t) => {
  const temporary = await scratch(t);
  const root = await ensureRoot(path.join(temporary, 'owned'));
  const layout = sourceLayout(root, 'win32-x64');
  await fs.mkdir(layout.directory, { recursive: true });
  await fs.writeFile(path.join(layout.directory, 'user-file.txt'), 'keep');
  await assert.rejects(owner(layout, root, 'win32-x64', true), /adopt/);
  assert.equal(await fs.readFile(path.join(layout.directory, 'user-file.txt'), 'utf8'), 'keep');
  const second = sourceLayout(root, 'darwin-arm64');
  await owner(second, root, 'darwin-arm64', true);
  await owner(second, root, 'darwin-arm64', false);
  await assert.rejects(
    owner({ ...second, sourceRevision: '0'.repeat(40) }, root, 'darwin-arm64', false),
    /revision/,
  );
  const third = sourceLayout(root, 'darwin-x64');
  await owner(third, root, 'darwin-x64', true);
  const foreign = path.join(temporary, 'foreign');
  await fs.mkdir(foreign);
  await fs.symlink(foreign, third.depot, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(owner(third, root, 'darwin-x64', false), /outside/);
});

test('pinned source preparation never resets an existing checkout or replaces its remote', async (t) => {
  const temporary = await scratch(t);
  const repo = path.join(temporary, 'source');
  await fs.mkdir(repo);
  await execute('git', ['init', repo], { capture: true });
  await execute('git', ['-C', repo, 'remote', 'add', 'origin', 'https://example.invalid/original.git'], {
    capture: true,
  });
  await fs.writeFile(path.join(repo, 'keep.txt'), 'keep');
  await assert.rejects(
    pinnedCheckout(repo, 'https://example.invalid/other.git', lock.sourceRevision, process.env),
    /remote/,
  );
  await assert.rejects(
    pinnedCheckout(repo, 'https://example.invalid/original.git', lock.sourceRevision, process.env),
    /overwrite/,
  );
  assert.equal(await fs.readFile(path.join(repo, 'keep.txt'), 'utf8'), 'keep');
  await execute('git', ['-C', repo, 'add', 'keep.txt'], { capture: true });
  await execute(
    'git',
    [
      '-C',
      repo,
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      'commit',
      '-m',
      'Fixture',
    ],
    { capture: true },
  );
  const head = await execute('git', ['-C', repo, 'rev-parse', 'HEAD'], { capture: true });
  await assert.rejects(
    pinnedCheckout(repo, 'https://example.invalid/original.git', lock.sourceRevision, process.env),
    /existing source revision/,
  );
  assert.equal(await execute('git', ['-C', repo, 'rev-parse', 'HEAD'], { capture: true }), head);
});
