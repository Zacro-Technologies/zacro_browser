'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { manifest, verifiedPatch, safeRelative, options, inspect } = require('../apply.cjs');
const native = require('../../build/native-build.lock.json');

test('patch identity matches the independent native source pin and exact changed paths', async () => {
  assert.equal(manifest.revision, native.sourceRevision);
  assert.equal(manifest.version, native.sourceVersion);
  assert.equal(manifest.product, native.productName);
  const patch = await fs.readFile(await verifiedPatch(), 'utf8');
  const changed = [...patch.matchAll(/^diff --git a\/(.+) b\/(.+)$/gm)];
  assert.deepEqual(changed.map((item) => item[1]).sort(), manifest.files.map((item) => item.path).sort());
  assert(changed.every((item) => item[1] === item[2]));
  assert(!/^(?:new file|deleted file|rename from|rename to|GIT binary patch)/m.test(patch));
  assert.equal(manifest.outputs['win32-x64'], 'chrome.exe');
  assert.equal(manifest.outputs['darwin-arm64'], manifest.outputs['darwin-x64']);
});

test('patch CLI and manifest path validation reject ambiguous or escaping inputs', () => {
  for (const input of ['', '../source', '/source', 'C:/source', 'a\\b', 'a//b', 'a/./b', 'a\0b'])
    assert.equal(safeRelative(input), false);
  assert.equal(safeRelative('chrome/app/theme/chromium/BRANDING'), true);
  for (const argv of [
    [],
    ['--apply'],
    ['--source', '--check'],
    ['--source', '/source', '--check', '--apply'],
    ['--source', '/source', '--check', '--unknown'],
    ['--source', '/source', '--source', '/other', '--apply'],
  ])
    assert.throws(() => options(argv));
  assert.deepEqual(options(['--source', '/source', '--check']), { source: '/source', operation: 'check' });
});

test(
  'an edited source file is rejected without modifying it or neighboring files',
  {
    skip: !process.env.ZACRO_BRANDING_REFERENCES,
  },
  async () => {
    const root = process.env.ZACRO_BRANDING_REFERENCES;
    const original = await inspect({ source: root, requireRevision: false });
    assert.equal(original.state, 'unpatched');
    const directory = await fs.mkdtemp(path.join(root, '.zacro-negative-test-'));
    for (const item of manifest.files) {
      const target = path.join(directory, item.path);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.copyFile(path.join(root, item.path), target);
    }
    const edited = path.join(directory, manifest.files[0].path);
    await fs.appendFile(edited, '# Deliberate local edit for rejection test.\n');
    const before = await Promise.all(
      manifest.files.map((item) => fs.readFile(path.join(directory, item.path))),
    );
    await assert.rejects(
      inspect({ source: directory, requireRevision: false }),
      /differs from both reviewed states/,
    );
    const after = await Promise.all(
      manifest.files.map((item) => fs.readFile(path.join(directory, item.path))),
    );
    assert.deepEqual(after, before);
  },
);
