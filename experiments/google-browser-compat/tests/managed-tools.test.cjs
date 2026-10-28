'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  managedTools,
  safeBootstrapPath,
  pythonRelativeDirectory,
  validateManagedEnvironment,
} = require('../build/managed-tools.cjs');
const { sourceEnvironment } = require('../build/native-source.cjs');
const lock = require('../build/native-build.lock.json');
const manifest = 'infra/3pp/tools/cpython3/${platform} version:2@3.11.8.chromium.35\n';

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-managed-tools-'));
  const depot = path.join(root, 'depot_tools');
  const relative = pythonRelativeDirectory(manifest);
  await fs.mkdir(path.join(depot, relative), { recursive: true });
  await fs.mkdir(path.join(depot, 'bootstrap'));
  await fs.mkdir(path.join(depot, '.cipd_bin'));
  await fs.writeFile(path.join(depot, 'bootstrap', 'manifest.txt'), manifest);
  await fs.writeFile(path.join(depot, 'python3_bin_reldir.txt'), relative);
  const python = path.join(depot, relative, process.platform === 'win32' ? 'python3.exe' : 'python3');
  const vpython = path.join(depot, '.cipd_bin', process.platform === 'win32' ? 'vpython3.exe' : 'vpython3');
  for (const filename of [python, vpython]) await fs.writeFile(filename, 'fixture only; never executed');
  const env = sourceEnvironment(depot, { PATH: '/original-path' });
  const state = {},
    calls = [];
  const execute = async (program, args, options) => {
    calls.push({ program, args, options });
    if (program !== 'git') {
      if (state.bootstrapFailure) throw new Error('simulated bootstrap failure');
      return '';
    }
    return args.includes('HEAD') ? state.head || lock.depotToolsRevision : state.dirty || '';
  };
  t.after(async () => {
    const real = await fs.realpath(root);
    assert.equal(path.dirname(real).toLowerCase(), (await fs.realpath(os.tmpdir())).toLowerCase());
    assert.ok(path.basename(real).startsWith('zacro-managed-tools-'));
    await fs.rm(real, { recursive: true, force: true });
  });
  return { root, layout: { depot }, env, execute, bootstrap: false, state, calls, python, vpython };
}

test('bootstrap paths and interpreter locations follow the exact platform manifest layout', () => {
  for (const filename of [
    'relative',
    path.resolve(os.tmpdir(), 'has space'),
    path.resolve(os.tmpdir(), 'has&command'),
  ])
    assert.throws(() => safeBootstrapPath(filename, 'win32'));
  assert.equal(pythonRelativeDirectory(manifest, 'win32'), 'bootstrap-2@3_11_8_chromium_35_bin/python3/bin');
  assert.equal(pythonRelativeDirectory(manifest, 'darwin'), 'bootstrap-2@3.11.8.chromium.35_bin/python3/bin');
  assert.throws(() => pythonRelativeDirectory(manifest + manifest), /one managed Python/);
});

test('managed tools reject bypasses and case-alias environment overrides', () => {
  const depot = path.resolve(os.tmpdir(), 'depot');
  const env = sourceEnvironment(depot, {});
  assert.doesNotThrow(() => validateManagedEnvironment(env, depot));
  assert.throws(() => validateManagedEnvironment({ ...env, depot_tools_update: '1' }, depot), /sanitized/);
  assert.throws(() => validateManagedEnvironment({ ...env, PYTHONPATH: 'foreign' }, depot), /override/);
  assert.throws(() => validateManagedEnvironment({ ...env, CIPD_CACHE_DIR: 'foreign' }, depot), /sanitized/);
});

test('managed tools resolve pinned executables and prepend Python for GN child processes', async (t) => {
  const context = await fixture(t);
  const result = await managedTools(context);
  assert.equal(result.python, context.python);
  assert.equal(result.vpython, context.vpython);
  assert.equal(context.env.PATH.split(path.delimiter)[0], path.dirname(context.python));
  assert.ok(context.calls.every((call) => call.program === 'git'));
});

test('changed depot and Python pointer are rejected without bootstrapping', async (t) => {
  const context = await fixture(t);
  context.state.dirty = ' M gclient.py';
  await assert.rejects(managedTools(context), /unreviewed/);
  context.state.dirty = '';
  const pointer = path.join(context.layout.depot, 'python3_bin_reldir.txt');
  await fs.writeFile(pointer, 'other-interpreter/bin');
  await assert.rejects(managedTools(context), /Python location/);
  assert.equal(await fs.readFile(pointer, 'utf8'), 'other-interpreter/bin');
  assert.ok(context.calls.every((call) => call.program === 'git'));
});

test('bootstrap errors propagate and only pinned native entrypoints are requested', async (t) => {
  const context = await fixture(t);
  context.state.bootstrapFailure = true;
  await assert.rejects(managedTools({ ...context, bootstrap: true }), /simulated bootstrap failure/);
  const command = context.calls.find((call) => call.program !== 'git');
  if (process.platform === 'win32') {
    assert.equal(command.program, 'cmd.exe');
    assert.equal(command.args.at(-1), path.join(context.layout.depot, 'bootstrap', 'win_tools.bat'));
  } else {
    assert.equal(command.program, '/bin/bash');
    assert.ok(command.args.includes('set -e; source "$1"; bootstrap_python3'));
  }
});

test('owned cache junctions cannot redirect bootstrap writes', async (t) => {
  const context = await fixture(t);
  const outside = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-managed-outside-'));
  t.after(async () => {
    await fs.rmdir(outside);
  });
  await fs.symlink(
    outside,
    path.join(context.layout.depot, '.zacro-cache'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(managedTools({ ...context, bootstrap: true }), /outside/);
  assert.ok(context.calls.every((call) => call.program === 'git'));
  assert.deepEqual(await fs.readdir(outside), []);
});
