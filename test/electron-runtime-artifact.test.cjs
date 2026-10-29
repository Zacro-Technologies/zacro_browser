'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { sealRuntime, verifyRuntime, installRuntime } = require('../scripts/electron-runtime-artifact.cjs');
const { nativeBinary } = require('./helpers/native-binary.cjs');

async function fixture(t, platform = 'darwin', arch = 'arm64') {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-runtime-artifact-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const dist = path.join(root, 'artifact');
  const main = path.join(
    dist,
    platform === 'darwin' ? 'Electron.app/Contents/MacOS/Electron' : 'electron.exe',
  );
  const dependency = path.join(
    dist,
    platform === 'darwin'
      ? 'Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework'
      : 'ffmpeg.dll',
  );
  await fs.mkdir(path.dirname(main), { recursive: true });
  await fs.mkdir(path.dirname(dependency), { recursive: true });
  await fs.writeFile(path.join(dist, 'version'), '45.0.0\n');
  await fs.writeFile(main, nativeBinary(platform, arch, true), { mode: 0o755 });
  await fs.writeFile(dependency, nativeBinary(platform, arch), { mode: 0o755 });
  if (platform === 'darwin') {
    const framework = path.dirname(path.dirname(path.dirname(dependency)));
    await fs.symlink('A', path.join(framework, 'Versions/Current'));
    await fs.symlink('Versions/Current/Electron Framework', path.join(framework, 'Electron Framework'));
  }
  return { root, dist, main, dependency };
}
const target = {
  platform: 'darwin',
  arch: 'arm64',
  identity: { electronVersion: '45.0.0', electronCommit: '1'.repeat(40), patchesSha256: '2'.repeat(64) },
};

test('runtime receipt verifies all regular files and internal framework symlinks', async (t) => {
  const { dist, dependency } = await fixture(t);
  const receipt = await sealRuntime(dist, target);
  assert.equal(receipt.electronVersion, '45.0.0');
  assert.equal((await verifyRuntime(dist, target)).files.length, 5);
  await fs.writeFile(dependency, 'changed');
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
  const { dist, root, dependency } = await fixture(t);
  await sealRuntime(dist, target);
  const destination = path.join(root, 'installed');
  await fs.mkdir(destination);
  await fs.writeFile(path.join(destination, 'old'), 'old runtime');
  const { backup } = await installRuntime(dist, { ...target, destination });
  assert.equal(await fs.readFile(path.join(backup, 'old'), 'utf8'), 'old runtime');
  await verifyRuntime(destination, target);
  await fs.writeFile(dependency, 'tampered');
  await assert.rejects(installRuntime(dist, { ...target, destination }), /integrity/i);
  await verifyRuntime(destination, target);
});

test('native magic finds extensionless dependencies and rejects foreign formats at the same architecture', async (t) => {
  for (const [platform, arch, foreign] of [
    ['darwin', 'arm64', 'win32'],
    ['darwin', 'x64', 'win32'],
    ['win32', 'x64', 'darwin'],
  ]) {
    const { dist } = await fixture(t, platform, arch);
    await fs.writeFile(path.join(dist, 'extensionless-helper'), nativeBinary(foreign, arch, true));
    await assert.rejects(sealRuntime(dist, { ...target, platform, arch }), /binary.*target|architecture/i);
  }
});

test('runtime rejects unsupported universal images and malformed named native dependencies', async (t) => {
  const fat = Buffer.alloc(8192 + 104);
  fat.writeUInt32BE(0xcafebabe, 0);
  fat.writeUInt32BE(2, 4);
  for (const [index, arch, cpu, subtype] of [
    [0, 'x64', 0x01000007, 3],
    [1, 'arm64', 0x0100000c, 0],
  ]) {
    const table = 8 + index * 20;
    const offset = (index + 1) * 4096;
    const image = nativeBinary('darwin', arch, true);
    fat.writeUInt32BE(cpu, table);
    fat.writeUInt32BE(subtype, table + 4);
    fat.writeUInt32BE(offset, table + 8);
    fat.writeUInt32BE(image.length, table + 12);
    fat.writeUInt32BE(12, table + 16);
    image.copy(fat, offset);
  }
  for (const [name, bytes] of [
    ['universal-helper', fat],
    ['broken.dylib', Buffer.from('invalid image')],
  ]) {
    const { dist } = await fixture(t);
    await fs.writeFile(path.join(dist, name), bytes);
    await assert.rejects(sealRuntime(dist, target), /binary.*target|architecture/i);
  }
});

for (const [platform, arch] of [
  ['darwin', 'arm64'],
  ['darwin', 'x64'],
  ['win32', 'x64'],
]) {
  for (const component of ['main', 'dependency']) {
    test(`seal rejects ${platform}/${arch} with wrong ${component} architecture`, async (t) => {
      const artifact = await fixture(t, platform, arch);
      await fs.writeFile(
        artifact[component],
        nativeBinary(platform, arch === 'arm64' ? 'x64' : 'arm64', component === 'main'),
      );
      await assert.rejects(
        sealRuntime(artifact.dist, { ...target, platform, arch }),
        /binary.*target|architecture/i,
      );
      await assert.rejects(fs.access(path.join(artifact.dist, 'zacro-runtime.json')), { code: 'ENOENT' });
    });

    test(`verify and install reject relabeled ${platform}/${arch} ${component} bytes despite matching hashes`, async (t) => {
      const artifact = await fixture(t, platform, arch);
      const options = { ...target, platform, arch };
      const receipt = await sealRuntime(artifact.dist, options);
      const bytes = nativeBinary(platform, arch === 'arm64' ? 'x64' : 'arm64', component === 'main');
      await fs.writeFile(artifact[component], bytes);
      const entry = receipt.files.find(
        (file) => file.path === path.relative(artifact.dist, artifact[component]).split(path.sep).join('/'),
      );
      entry.size = bytes.length;
      entry.sha256 = createHash('sha256').update(bytes).digest('hex');
      await fs.writeFile(path.join(artifact.dist, 'zacro-runtime.json'), JSON.stringify(receipt));
      await assert.rejects(verifyRuntime(artifact.dist, options), /binary.*target|architecture/i);
      const destination = path.join(artifact.root, 'installed');
      await fs.mkdir(destination);
      await fs.writeFile(path.join(destination, 'old'), 'old runtime');
      await assert.rejects(
        installRuntime(artifact.dist, { ...options, destination }),
        /binary.*target|architecture/i,
      );
      assert.equal(await fs.readFile(path.join(destination, 'old'), 'utf8'), 'old runtime');
      assert.deepEqual((await fs.readdir(artifact.root)).sort(), ['artifact', 'installed']);
    });
  }
}
