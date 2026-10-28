'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { options, createFixtureDirectory, fixtureRequestAllowed } = require('../mechanics.cjs');
const { ensureRoot } = require('../lib/paths.cjs');
const { manualEnvironment } = require('../cli.cjs');

const id = '12345678-1234-1234-1234-123456789abc';
const native = { engine: 'zacro-native', platform: 'win32-x64', configuration: 'native-branded' };

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-mechanics-isolation-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    const parent = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), parent.toLowerCase());
    assert.match(path.basename(real), /^zacro-mechanics-isolation-test-/u);
    await fs.rm(real, { recursive: true });
  });
  return ensureRoot(path.join(directory, 'owned'));
}

test('native mechanics accepts only fixture options, never an account URL or profile path', () => {
  assert.deepEqual(options(['--engine', 'zacro-native']), { engine: 'zacro-native', workspace: false });
  for (const args of [
    ['--engine', 'zacro-native', '--url', 'https://accounts.google.com/'],
    ['--engine', 'zacro-native', '--profile', 'manual'],
    ['--engine', 'zacro-native', '--role', 'regular-a'],
    ['--engine', 'zacro-native', '--workspace'],
    ['--engine', 'brave', '--workspace'],
  ])
    assert.throws(() => options(args));
});

test('fixture ownership is exclusive and cannot adopt an existing directory or linked parent', async (t) => {
  const root = await scratch(t);
  const manual = path.join(root, 'profiles', 'manual');
  await fs.mkdir(manual, { recursive: true });
  await fs.writeFile(path.join(manual, 'fixture-sentinel'), 'keep untouched');
  const directory = await createFixtureDirectory(root, native, id);
  assert.equal(path.dirname(directory), path.join(root, 'fixtures'));
  const marker = await fs.readFile(path.join(directory, '.fixture-owner.json'), 'utf8');
  assert.deepEqual(JSON.parse(marker), {
    kind: 'local-browser-mechanics',
    automation: true,
    platform: native.platform,
    engine: native.engine,
    configuration: native.configuration,
  });
  await assert.rejects(createFixtureDirectory(root, native, id), { code: 'EEXIST' });
  assert.equal(await fs.readFile(path.join(directory, '.fixture-owner.json'), 'utf8'), marker);
  await assert.rejects(createFixtureDirectory(root, native, '../manual'));
  assert.equal(await fs.readFile(path.join(manual, 'fixture-sentinel'), 'utf8'), 'keep untouched');
  const second = await ensureRoot(path.join(path.dirname(root), 'second-owned'));
  const profiles = path.join(second, 'profiles');
  await fs.mkdir(profiles);
  await fs.symlink(
    profiles,
    path.join(second, 'fixtures'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(createFixtureDirectory(second, native, id), /must-not-be-link/u);
  assert.deepEqual(await fs.readdir(profiles), []);
});

test('fixture routes allow only exact loopback origins and the opted-in workspace extension', () => {
  const origins = new Set(['http://127.0.0.1:53000', 'http://127.0.0.1:53001']);
  assert.equal(fixtureRequestAllowed('http://127.0.0.1:53000/second', origins), true);
  assert.equal(fixtureRequestAllowed('http://127.0.0.1:53001/callback', origins), true);
  const extension = 'chrome-extension://fimeokmnmdjlnadhinihgiaimdfinehg/panel.html';
  assert.equal(fixtureRequestAllowed(extension, origins), false);
  assert.equal(fixtureRequestAllowed(extension, origins, true), true);
  for (const address of [
    'https://accounts.google.com/',
    'https://127.0.0.1:53000/',
    'http://127.0.0.1:53002/',
    'http://localhost:53000/',
    'http://name:secret@127.0.0.1:53000/',
    'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/panel.html',
    'file:///private',
    'not a URL',
  ])
    assert.equal(fixtureRequestAllowed(address, origins, true), false);
});

test('fixture launch environment removes case-insensitive profile, credential and logging overrides', () => {
  const original = {
    Path: 'keep',
    ordinary: 'keep',
    chrome_user_data_dir: 'unrelated profile',
    ChRoMe_EnAbLe_LoGgInG: '1',
    google_api_key: 'private-placeholder',
    sSlKeYlOgFiLe: 'private-placeholder',
    NODE_OPTIONS: 'private-placeholder',
  };
  assert.deepEqual(manualEnvironment(original), { Path: 'keep', ordinary: 'keep' });
  assert.equal(original.chrome_user_data_dir, 'unrelated profile');
});
