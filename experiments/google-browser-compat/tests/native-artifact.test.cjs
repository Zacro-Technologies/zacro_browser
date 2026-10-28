'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execute = promisify(execFile);
const lock = require('../build/native-build.lock.json');
const branding = require('../native-branding/manifest.json');
const { writeStoredZip, digests } = require('../lib/artifacts.cjs');
const { macInventory } = require('../build/runtime-inventory.cjs');
const api = require('../build/native-artifact.cjs');
const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
const platform = `${process.platform}-${process.arch}`;
const native = lock.platforms.includes(platform);
const run = 'https://github.com/Zacro-Technologies/zacro_browser/actions/runs/123456/attempts/1';

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-artifact-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    assert.equal(path.dirname(real).toLowerCase(), (await fs.realpath(os.tmpdir())).toLowerCase());
    assert.ok(path.basename(real).startsWith('zacro-native-artifact-test-'));
    await fs.rm(real, { recursive: true, force: true });
  });
  return directory;
}

async function receiptFixture(selectedPlatform = 'win32-x64', files) {
  const executable = branding.outputs[selectedPlatform];
  files ||= [{ path: executable, sha256: sha256('fixture-only') }];
  const configured = {
    schemaVersion: 1,
    productName: lock.productName,
    platform: selectedPlatform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    depotToolsRevision: lock.depotToolsRevision,
    brandingPatchSha256: branding.patch.sha256,
    gnArgsSha256: sha256(
      await fs.readFile(path.join(__dirname, `../build/native-args.${selectedPlatform}.gn`)),
    ),
    syncEvidence: { receipt: { sourceRevision: lock.sourceRevision }, dependencyCount: 1 },
    configuredAt: '2026-10-29T01:00:00.000Z',
    compiled: false,
  };
  const built = {
    ...configured,
    configurationSha256: sha256(JSON.stringify(configured)),
    builtAt: '2026-10-29T02:00:00.000Z',
    executableRelative: executable,
    executableSha256: files.find((file) => file.path === executable).sha256,
    runtimeSha256: sha256(JSON.stringify(files)),
    compiled: true,
    files,
    signedForDistribution: false,
    googleAcceptance: 'untested',
  };
  const packaged = {
    schemaVersion: 1,
    productName: lock.productName,
    platform: selectedPlatform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: branding.patch.sha256,
    executableSha256: built.executableSha256,
    runtimeSha256: built.runtimeSha256,
    compiled: true,
    signedForDistribution: false,
    googleAcceptance: 'untested',
    destination: 'CI-only path; never used locally',
    size: 1,
    sha256: 'a'.repeat(64),
  };
  return { built, packaged };
}

async function archiveFixture(t) {
  const directory = await scratch(t),
    input = path.join(directory, 'input');
  await fs.mkdir(input);
  const root = path.join(directory, 'owned'),
    archive = path.join(input, 'prototype.zip');
  let files;
  if (platform === 'win32-x64') {
    files = [
      { path: 'chrome.exe', sha256: sha256('fixture-only') },
      { path: 'resources/fixture.pak', sha256: sha256('fixture-resource') },
    ];
  } else {
    const bundle = path.join(input, 'Zacro Prototype.app');
    await fs.mkdir(path.join(bundle, 'Contents', 'MacOS'), { recursive: true });
    await fs.writeFile(path.join(bundle, 'Contents', 'MacOS', 'Zacro Prototype'), 'fixture-only');
    const framework = path.join(bundle, 'Contents', 'Frameworks', 'Fixture.framework');
    await fs.mkdir(path.join(framework, 'Versions', 'A'), { recursive: true });
    await fs.writeFile(path.join(framework, 'Versions', 'A', 'Fixture'), 'fixture-framework');
    await fs.symlink('A', path.join(framework, 'Versions', 'Current'));
    await fs.symlink('Versions/Current/Fixture', path.join(framework, 'Fixture'));
    await execute('/usr/bin/xattr', ['-w', 'com.zacro.fixture', 'fixture metadata', bundle]);
    files = await macInventory(bundle);
  }
  const { built, packaged } = await receiptFixture(platform, files);
  if (platform === 'win32-x64') {
    await writeStoredZip(archive, [
      { name: 'Zacro Prototype/chrome.exe', data: 'fixture-only' },
      { name: 'Zacro Prototype/resources/fixture.pak', data: 'fixture-resource' },
      {
        name: 'Zacro Prototype/NATIVE-BUILD.json',
        data: JSON.stringify({ ...built, files: undefined }, null, 2) + '\n',
      },
      { name: 'Zacro Prototype/LICENSE.chromium', data: 'fixture-license' },
    ]);
  } else
    await execute('/usr/bin/ditto', [
      '-c',
      '-k',
      '--sequesterRsrc',
      '--keepParent',
      path.join(input, 'Zacro Prototype.app'),
      archive,
    ]);
  Object.assign(packaged, await digests(archive));
  const buildReceipt = path.join(input, 'build.json'),
    packageReceipt = path.join(input, 'prototype.zip.json');
  await fs.writeFile(buildReceipt, JSON.stringify(built, null, 2) + '\n');
  await fs.writeFile(packageReceipt, JSON.stringify(packaged, null, 2) + '\n');
  return {
    directory,
    root,
    archive,
    built,
    packaged,
    args: { root, archive, 'build-receipt': buildReceipt, 'package-receipt': packageReceipt, 'ci-run': run },
  };
}

test('artifact CLI requires explicit files and exposes only closed manual launch options', () => {
  assert.equal(api.options(['verify', '--artifact', 'a'.repeat(64)]).artifact, 'a'.repeat(64));
  for (const args of [
    [],
    ['import', '--archive', 'relative'],
    ['launch', '--artifact', 'a'.repeat(64), '--role', 'regular-a', '--flags', '--no-sandbox'],
    ['verify', '--artifact', '../escape'],
  ])
    assert.throws(() => api.options(args));
  for (const value of [
    'http://github.com/a/b/actions/runs/1',
    'https://github.com/a/b/actions/runs/1?token=secret',
    'https://example.com/a/b/actions/runs/1',
  ])
    assert.throws(() => api.ciRunURL(value));
  const flags = api.launchFlags(path.resolve(os.tmpdir(), 'isolated'), 'private', 'about:blank');
  assert.equal(flags.filter((flag) => flag === '--incognito').length, 1);
  assert.ok(flags.every((flag) => !/debugging|no-sandbox|disable-web-security|user-agent/.test(flag)));
  assert.throws(() =>
    api.launchFlags(
      path.resolve(os.tmpdir(), 'isolated'),
      'regular-a',
      'https://accounts.google.com/?secret=1',
    ),
  );
});

test('receipt binding rejects uncompiled, mismatched and modified runtime claims', async () => {
  const { built, packaged } = await receiptFixture();
  await api.validateReceipts(packaged, built);
  for (const mutation of [
    { compiled: false },
    { sourceRevision: '0'.repeat(40) },
    { productName: 'Other' },
    { brandingPatchSha256: '0'.repeat(64) },
    { runtimeSha256: '0'.repeat(64) },
    { executableSha256: '0'.repeat(64) },
    { configurationSha256: '0'.repeat(64) },
    { gnArgsSha256: '0'.repeat(64) },
    { files: [] },
  ])
    await assert.rejects(api.validateReceipts(packaged, { ...built, ...mutation }));
  await assert.rejects(
    api.validateReceipts({ ...packaged, platform: 'darwin-arm64' }, built),
    /different runtimes/,
  );
});

test('archive containment rejects extra executables, traversal and Windows symlinks', async () => {
  const { built } = await receiptFixture();
  const entries = [
    'Zacro Prototype/chrome.exe',
    'Zacro Prototype/NATIVE-BUILD.json',
    'Zacro Prototype/LICENSE.chromium',
  ].map((name) => ({ name, mode: 0o100644 }));
  assert.doesNotThrow(() => api.validateArchiveEntries({ entries }, built));
  assert.throws(
    () =>
      api.validateArchiveEntries(
        { entries: [...entries, { name: 'Zacro Prototype/extra.dll', mode: 0o100644 }] },
        built,
      ),
    /outside/,
  );
  assert.throws(
    () =>
      api.validateArchiveEntries({ entries: [...entries, { name: '../escape.exe', mode: 0o100644 }] }, built),
    /traversal/,
  );
  assert.throws(
    () =>
      api.validateArchiveEntries(
        { entries: entries.map((entry, index) => (index === 0 ? { ...entry, mode: 0o120777 } : entry)) },
        built,
      ),
    /symbolic links/,
  );
});

test('Mac AppleDouble root and child metadata must map to real bundle members', () => {
  const built = {
    platform: 'darwin-arm64',
    files: [
      { path: 'Zacro Prototype.app', type: 'directory' },
      { path: 'Zacro Prototype.app/Contents', type: 'directory' },
    ],
  };
  const entries = [
    { name: 'Zacro Prototype.app/', mode: 0o40755 },
    { name: 'Zacro Prototype.app/Contents/', mode: 0o40755 },
    { name: '__MACOSX/', mode: 0o40755 },
    { name: '__MACOSX/._Zacro Prototype.app', mode: 0o100644 },
    { name: '__MACOSX/Zacro Prototype.app/._Contents', mode: 0o100644 },
  ];
  assert.doesNotThrow(() => api.validateArchiveEntries({ entries }, built));
  assert.throws(
    () =>
      api.validateArchiveEntries(
        { entries: [...entries, { name: '__MACOSX/Zacro Prototype.app/._Unknown', mode: 0o100644 }] },
        built,
      ),
    /does not map/,
  );
});

test(
  'native extraction verifies and reuses an imported fixture without source tools or execution',
  { skip: !native },
  async (t) => {
    const fixture = await archiveFixture(t);
    const imported = await api.importArtifact(fixture.args);
    assert.equal(imported.locallyCompiled, false);
    assert.equal(imported.sourceBuildReported, true);
    assert.match(imported.ciProvenance, /operator-supplied/);
    const runtime = await api.verifyImported({ root: fixture.root, artifact: imported.artifactId });
    assert.equal(await fs.readFile(runtime.executable, 'utf8'), 'fixture-only');
    assert.equal((await api.importArtifact(fixture.args)).importedAt, imported.importedAt);
    await assert.rejects(
      api.importArtifact({ ...fixture.args, 'ci-run': run.replace('123456', '654321') }),
      /different provenance/,
    );
  },
);

test('archive mismatch is rejected before creating an import root', { skip: !native }, async (t) => {
  const fixture = await archiveFixture(t);
  await fs.appendFile(fixture.archive, 'changed');
  await assert.rejects(api.importArtifact(fixture.args), /does not match/);
  await assert.rejects(fs.access(fixture.root), { code: 'ENOENT' });
});

test('tampered runtime is rejected before a manual browser launch', { skip: !native }, async (t) => {
  const fixture = await archiveFixture(t),
    imported = await api.importArtifact(fixture.args);
  const runtime = await api.verifyImported({ root: fixture.root, artifact: imported.artifactId });
  await fs.writeFile(runtime.executable, 'changed executable');
  await assert.rejects(
    api.launchImported({ root: fixture.root, artifact: imported.artifactId, role: 'regular-a' }),
    /inventory/,
  );
  await assert.rejects(fs.access(path.join(fixture.root, 'profiles')), { code: 'ENOENT' });
});

test('imported manual profiles isolate roles and retain foreign data', { skip: !native }, async (t) => {
  const fixture = await archiveFixture(t),
    imported = await api.importArtifact(fixture.args);
  const runtime = await api.verifyImported({ root: fixture.root, artifact: imported.artifactId });
  const first = await api.ensureImportedProfile(runtime, 'regular-a');
  const second = await api.ensureImportedProfile(runtime, 'regular-b');
  assert.notEqual(first, second);
  const privateDirectory = path.join(path.dirname(first), 'private');
  await fs.mkdir(privateDirectory);
  await fs.writeFile(path.join(privateDirectory, 'keep.txt'), 'foreign');
  await assert.rejects(api.ensureImportedProfile(runtime, 'private'), /adopt/);
  assert.equal(await fs.readFile(path.join(privateDirectory, 'keep.txt'), 'utf8'), 'foreign');
});
