'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { windowsInventory, macInventory } = require('../build/runtime-inventory.cjs');

const hash = (value) => createHash('sha256').update(value).digest('hex');
const run = promisify(execFile);

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-runtime-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    const parent = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), parent.toLowerCase());
    assert.match(path.basename(real), /^zacro-native-runtime-test-/u);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}

async function put(root, relative, data, mode) {
  const filename = path.join(root, ...relative.split('/'));
  await fs.mkdir(path.dirname(filename), { recursive: true });
  await fs.writeFile(filename, data, mode === undefined ? {} : { mode });
  return filename;
}

async function bundleFixture(root) {
  const bundle = path.join(root, 'Zacro Prototype.app');
  await put(bundle, 'Contents/MacOS/Zacro Prototype', 'fixture launcher', 0o755);
  await put(bundle, 'Contents/Info.plist', 'fixture plist', 0o644);
  await put(
    bundle,
    'Contents/Frameworks/Zacro Framework.framework/Versions/156/Zacro Framework',
    'fixture engine',
    0o755,
  );
  await fs.mkdir(path.join(bundle, 'Contents', 'Resources', 'empty'), { recursive: true });
  return bundle;
}

async function frameworkLinks(bundle) {
  const framework = path.join(bundle, 'Contents', 'Frameworks', 'Zacro Framework.framework');
  await fs.symlink('156', path.join(framework, 'Versions', 'Current'), 'dir');
  await fs.symlink('Versions/Current/Zacro Framework', path.join(framework, 'Zacro Framework'), 'file');
}

test('Windows GN dependency closure preserves relative layout, deduplicates and excludes unrelated build files', async (t) => {
  const root = await scratch(t);
  const out = path.join(root, 'out');
  await put(out, 'chrome.exe', 'reordered launcher');
  await put(out, 'initialexe/chrome.exe', 'initial launcher');
  await put(out, 'chrome.dll', 'engine');
  await put(out, 'locales/en-US.pak', 'english');
  await put(out, 'locales/ja.pak', 'japanese');
  await put(out, 'resources/subdir/data.pak', 'resource');
  await put(out, 'First Run', 'marker');
  await put(out, 'obj/not-runtime.obj', 'do not bundle');
  const dependencies =
    'chrome.dll\r\nlocales/\r\n./chrome.exe\r\nresources/\r\nFirst Run\r\nlocales\\en-US.pak\r\nchrome.exe\r\n';
  const inventory = await windowsInventory(out, dependencies);
  assert.deepEqual(
    inventory.map((entry) => entry.path),
    [
      'First Run',
      'chrome.dll',
      'chrome.exe',
      'locales/en-US.pak',
      'locales/ja.pak',
      'resources/subdir/data.pak',
    ],
  );
  assert.deepEqual(
    inventory.find((entry) => entry.path === 'chrome.exe'),
    {
      path: 'chrome.exe',
      sha256: hash('reordered launcher'),
    },
  );
  const reversed = dependencies.trim().split(/\r?\n/u).reverse().join('\n');
  assert.deepEqual(await windowsInventory(out, reversed), inventory);
  await fs.writeFile(path.join(out, 'chrome.dll'), 'changed engine');
  const rebuilt = await windowsInventory(out, dependencies);
  assert.notEqual(hash(JSON.stringify(rebuilt)), hash(JSON.stringify(inventory)));
  assert.deepEqual(
    rebuilt.find((entry) => entry.path === 'chrome.exe'),
    inventory.find((entry) => entry.path === 'chrome.exe'),
  );
  await assert.rejects(windowsInventory(out, 'initialexe/chrome.exe\nchrome.dll\n'), /Final chrome.exe/u);
});

test('Windows inventory rejects traversal, absolute paths, alternate streams and link ancestors', async (t) => {
  const root = await scratch(t);
  const out = path.join(root, 'out');
  await put(out, 'chrome.exe', 'launcher');
  await put(out, 'resources/data.pak', 'resource');
  await put(root, 'outside.dat', 'outside');
  for (const dependency of [
    '../outside.dat',
    'resources/../chrome.exe',
    '/chrome.exe',
    '\\chrome.exe',
    'C:\\chrome.exe',
    'C:chrome.exe',
    '//server/share/file',
    'chrome.exe:stream',
    'resources//data.pak',
    ' chrome.exe',
    'chrome.exe ',
    '.',
    './',
    'NUL',
    'resources./data.pak',
  ])
    await assert.rejects(windowsInventory(out, `chrome.exe\n${dependency}\n`));
  await fs.symlink(
    path.join(out, 'resources'),
    path.join(out, 'linked'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(windowsInventory(out, 'chrome.exe\nlinked/\n'), /links/u);
  await assert.rejects(windowsInventory(out, 'chrome.exe\nlinked/data.pak\n'), /links/u);
  await fs.symlink(out, path.join(root, 'linked-root'), process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(windowsInventory(path.join(root, 'linked-root'), 'chrome.exe'), /ordinary directory/u);
});

test('Mac inventory includes root and empty directory modes and hashes real executable bytes', async (t) => {
  const root = await scratch(t);
  const bundle = await bundleFixture(root);
  const inventory = await macInventory(bundle);
  assert.equal(inventory[0].path, 'Zacro Prototype.app');
  assert.equal(inventory[0].type, 'directory');
  assert.equal(inventory[0].mode, (await fs.lstat(bundle)).mode & 0o7777);
  assert.ok(
    inventory.some(
      (entry) => entry.path === 'Zacro Prototype.app/Contents/Resources/empty' && entry.type === 'directory',
    ),
  );
  const executable = inventory.find(
    (entry) => entry.path === 'Zacro Prototype.app/Contents/MacOS/Zacro Prototype',
  );
  assert.equal(executable.type, 'file');
  assert.equal(executable.sha256, hash('fixture launcher'));
  assert.ok(inventory.every((entry) => Number.isInteger(entry.mode)));
  assert.deepEqual(await macInventory(bundle), inventory);
});

test(
  'Mac executable and directory permission changes invalidate inventory without changing file hashes',
  {
    skip:
      process.platform === 'win32'
        ? 'Windows chmod does not expose Unix executable/directory permissions.'
        : false,
  },
  async (t) => {
    const root = await scratch(t);
    const bundle = await bundleFixture(root);
    const executable = path.join(bundle, 'Contents', 'MacOS', 'Zacro Prototype');
    await fs.chmod(executable, 0o755);
    await fs.chmod(bundle, 0o755);
    const before = await macInventory(bundle);
    await fs.chmod(executable, 0o644);
    const changedExecutable = await macInventory(bundle);
    assert.notDeepEqual(changedExecutable, before);
    assert.deepEqual(
      changedExecutable.filter((entry) => entry.sha256).map((entry) => entry.sha256),
      before.filter((entry) => entry.sha256).map((entry) => entry.sha256),
    );
    await fs.chmod(bundle, 0o700);
    assert.notDeepEqual(await macInventory(bundle), changedExecutable);
  },
);

test('Mac framework symlinks remain links with contained relative targets', async (t) => {
  const root = await scratch(t);
  const bundle = await bundleFixture(root);
  try {
    await frameworkLinks(bundle);
  } catch (error) {
    if (process.platform === 'win32' && ['EPERM', 'EACCES'].includes(error.code))
      return t.skip('This Windows host cannot create relative symbolic links.');
    throw error;
  }
  const inventory = await macInventory(bundle);
  const links = inventory.filter((entry) => entry.type === 'symlink');
  assert.equal(links.length, 2);
  assert.deepEqual(links.map((entry) => entry.link).sort(), ['156', 'Versions/Current/Zacro Framework']);
  assert.ok(links.every((entry) => Number.isInteger(entry.mode) && entry.sha256 === undefined));
  assert.equal(inventory.filter((entry) => entry.sha256 === hash('fixture engine')).length, 1);
});

test('Mac inventory rejects absolute, escaping, dangling and cyclic framework links', async (t) => {
  const root = await scratch(t);
  const bundle = await bundleFixture(root);
  const outside = await put(root, 'outside', 'outside');
  const link = path.join(bundle, 'Contents', 'escape');
  try {
    await fs.symlink(outside, link, 'file');
  } catch (error) {
    if (process.platform === 'win32' && ['EPERM', 'EACCES'].includes(error.code))
      return t.skip('This Windows host cannot create relative symbolic links.');
    throw error;
  }
  await assert.rejects(macInventory(bundle), /relative targets/u);
  await fs.unlink(link);
  await fs.symlink('../../outside', link, 'file');
  await assert.rejects(macInventory(bundle), /escapes/u);
  await fs.unlink(link);
  await fs.symlink('missing', link, 'file');
  await assert.rejects(macInventory(bundle));
  await fs.unlink(link);
  await fs.symlink('escape', link, 'file');
  await assert.rejects(macInventory(bundle));
});

test(
  'native Mac ditto ZIP roundtrip preserves the complete runtime inventory',
  { skip: process.platform !== 'darwin' ? 'Requires native macOS ditto and filesystem modes.' : false },
  async (t) => {
    const root = await scratch(t);
    const bundle = await bundleFixture(root);
    await frameworkLinks(bundle);
    await fs.chmod(bundle, 0o750);
    await fs.chmod(path.join(bundle, 'Contents', 'Resources', 'empty'), 0o710);
    const before = await macInventory(bundle);
    const archive = path.join(root, 'fixture.zip');
    const extracted = path.join(root, 'extracted');
    await fs.mkdir(extracted);
    await run('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', bundle, archive], {
      timeout: 20000,
    });
    await run('/usr/bin/ditto', ['-x', '-k', archive, extracted], { timeout: 20000 });
    const after = await macInventory(path.join(extracted, 'Zacro Prototype.app'));
    assert.deepEqual(after, before);
    assert.equal(hash(JSON.stringify(after)), hash(JSON.stringify(before)));
  },
);
