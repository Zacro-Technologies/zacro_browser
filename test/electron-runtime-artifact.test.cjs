'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { sealRuntime, verifyRuntime, installRuntime } = require('../scripts/electron-runtime-artifact.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-runtime-artifact-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const dist = path.join(root, 'artifact');
  await fs.mkdir(path.join(dist, 'framework'), { recursive: true });
  await fs.writeFile(path.join(dist, 'version'), '45.0.0\n');
  await fs.writeFile(path.join(dist, 'framework', 'binary'), 'synthetic binary fixture');
  return { root, dist };
}
const target = {
  platform: 'darwin',
  arch: 'arm64',
  identity: { electronVersion: '45.0.0', electronCommit: '1'.repeat(40), patchesSha256: '2'.repeat(64) },
};

test('runtime receipt verifies all regular files and internal framework symlinks', async (t) => {
  const { dist } = await fixture(t);
  await fs.symlink('framework/binary', path.join(dist, 'current'));
  const receipt = await sealRuntime(dist, target);
  assert.equal(receipt.electronVersion, '45.0.0');
  assert.equal((await verifyRuntime(dist, target)).files.length, 3);
  await fs.writeFile(path.join(dist, 'framework', 'binary'), 'changed');
  await assert.rejects(verifyRuntime(dist, target), /integrity/i);
});

test('runtime receipt rejects extra files, escaping links and wrong target', async (t) => {
  const { dist, root } = await fixture(t);
  await sealRuntime(dist, target);
  await assert.rejects(verifyRuntime(dist, { ...target, arch: 'x64' }), /target/i);
  await fs.writeFile(path.join(dist, 'injected'), 'unlisted code');
  await assert.rejects(verifyRuntime(dist, target), /integrity/i);
  await fs.rm(path.join(dist, 'injected'));
  await fs.writeFile(path.join(root, 'outside'), 'outside');
  await fs.symlink('../outside', path.join(dist, 'escape'));
  await assert.rejects(sealRuntime(dist, target), /outside/i);
});

test('runtime receipt rejects upstream or patch identity mismatches', async (t) => {
  const { dist } = await fixture(t);
  await sealRuntime(dist, target);
  const file = path.join(dist, 'zacro-runtime.json');
  const receipt = JSON.parse(await fs.readFile(file, 'utf8'));
  receipt.electronCommit = '0'.repeat(40);
  await fs.writeFile(file, JSON.stringify(receipt));
  await assert.rejects(verifyRuntime(dist, target), /identity/i);
});

test('install validates staged contents and preserves previous runtime in returned backup', async (t) => {
  const { dist, root } = await fixture(t);
  await sealRuntime(dist, target);
  const destination = path.join(root, 'installed');
  await fs.mkdir(destination);
  await fs.writeFile(path.join(destination, 'old'), 'old runtime');
  const { backup } = await installRuntime(dist, { ...target, destination });
  assert.equal(await fs.readFile(path.join(backup, 'old'), 'utf8'), 'old runtime');
  await verifyRuntime(destination, target);
  await fs.writeFile(path.join(dist, 'framework', 'binary'), 'tampered');
  await assert.rejects(installRuntime(dist, { ...target, destination }), /integrity/i);
  await verifyRuntime(destination, target);
});
