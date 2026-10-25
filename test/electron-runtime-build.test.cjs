'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { buildOptions, series } = require('../scripts/build-electron-runtime.cjs');
const build = require('../runtime/electron/build.json');

test('build root validation rejects general directories, incompatible targets and shell characters', () => {
  for (const root of [
    '.',
    '/',
    process.env.HOME,
    path.resolve(__dirname, '..'),
    '/tmp/with space',
    '/tmp/test;command',
    '/tmp/test&command',
  ])
    assert.throws(() => buildOptions(root), /root|dedicated|characters/i);
  assert.throws(() => buildOptions(path.join(os.tmpdir(), 'zacro-build'), 'universal'), /target/);
});

test('patch series validates pinned source, file boundaries and content before applying', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-patch-series-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const patch = 'synthetic patch fixture\n';
  await fs.writeFile(path.join(root, '0001-test.patch'), patch);
  const manifest = {
    schemaVersion: 1,
    electron: { version: build.electronVersion, commit: build.electronCommit },
    chromium: { version: build.chromiumVersion },
    patches: [
      {
        file: '0001-test.patch',
        target: 'electron',
        strip: 1,
        sha256: createHash('sha256').update(patch).digest('hex'),
      },
    ],
  };
  const save = () => fs.writeFile(path.join(root, 'series.json'), JSON.stringify(manifest));
  await save();
  assert.equal((await series(root)).patches.length, 1);
  await fs.writeFile(path.join(root, '0001-test.patch'), 'altered patch');
  await assert.rejects(series(root), /integrity/);
  manifest.patches[0].file = '../outside.patch';
  await save();
  await assert.rejects(series(root), /entry/);
  manifest.electron.commit = '0'.repeat(40);
  await save();
  await assert.rejects(series(root), /identity/);
});
