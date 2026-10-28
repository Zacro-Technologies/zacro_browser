'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const manifest = require('../build/windows-installers.lock.json');
const script = path.resolve(__dirname, '../build/provision-windows.ps1');
const { repositoryRoot, toolkitRoot } = require('../lib/paths.cjs');
const windows = process.platform === 'win32';

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-provision-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory),
      temporary = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), temporary.toLowerCase());
    assert.match(path.basename(real), /^zacro-provision-test-/);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}
function invoke(...args) {
  const result = spawnSync(
    'powershell.exe',
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', script, ...args],
    { encoding: 'utf8', windowsHide: true, timeout: 15000 },
  );
  assert.ifError(result.error);
  return { ...result, text: result.stdout + result.stderr };
}

test('provisioning pins small Microsoft installers and selects full C++/SDK prerequisites', () => {
  assert.equal(manifest.schemaVersion, 1);
  assert.deepEqual(
    manifest.installers.map((entry) => entry.id),
    ['visual-studio', 'windows-sdk'],
  );
  for (const entry of manifest.installers) {
    const url = new URL(entry.url);
    assert.equal(url.protocol, 'https:');
    assert.ok(['download.visualstudio.microsoft.com', 'download.microsoft.com'].includes(url.hostname));
    assert.match(entry.sha256, /^[a-f0-9]{64}$/);
    assert.equal(entry.file, path.basename(entry.file));
    assert.ok(entry.bytes > 0 && entry.bytes < 16 * 1024 ** 2);
    assert.match(entry.sha256Provenance, /Authenticode/);
  }
  const vs = manifest.installers[0],
    sdk = manifest.installers[1];
  assert.ok(vs.components.includes('Microsoft.VisualStudio.Component.VC.Tools.x86.x64'));
  assert.ok(vs.components.includes('Microsoft.VisualStudio.Component.VC.ATLMFC'));
  assert.ok(sdk.features.includes('OptionId.DesktopCPPx64'));
  assert.ok(sdk.features.includes('OptionId.WindowsDesktopDebuggers'));
});

test(
  'provisioning refuses repository, volume, and relative destinations before writing',
  { skip: !windows },
  () => {
    for (const root of [repositoryRoot || toolkitRoot, path.parse(script).root, 'relative-folder']) {
      const result = invoke('-ExternalRoot', root);
      assert.notEqual(result.status, 0);
      assert.match(result.text, /dedicated directory|outside the repository/);
    }
  },
);

test('provisioning preserves nonempty foreign roots and rejects junctions', { skip: !windows }, async (t) => {
  const directory = await scratch(t),
    foreign = path.join(directory, 'foreign');
  await fs.mkdir(foreign);
  await fs.writeFile(path.join(foreign, 'keep.txt'), 'existing data');
  const rejected = invoke('-ExternalRoot', foreign);
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.text, /Refusing to adopt/);
  assert.equal(await fs.readFile(path.join(foreign, 'keep.txt'), 'utf8'), 'existing data');
  const link = path.join(directory, 'redirect');
  await fs.symlink(foreign, link, 'junction');
  const redirected = invoke('-ExternalRoot', path.join(link, 'new-cache'));
  assert.notEqual(redirected.status, 0);
  assert.match(redirected.text, /junction or symbolic link/);
  await assert.rejects(fs.access(path.join(foreign, 'new-cache')));
});

test(
  'validation never downloads missing files and never replaces corrupt cached files',
  { skip: !windows },
  async (t) => {
    const directory = await scratch(t),
      root = path.join(directory, 'owned');
    const missing = invoke('-ExternalRoot', root);
    assert.notEqual(missing.status, 0);
    assert.match(missing.text, /Run this script with -Download first/);
    const owner = JSON.parse(await fs.readFile(path.join(root, '.zacro-native-toolchain.json'), 'utf8'));
    assert.equal(owner.root, root);
    const cached = path.join(root, 'installers', manifest.installers[0].file);
    await fs.writeFile(cached, 'corrupt existing bytes');
    const corrupt = invoke('-ExternalRoot', root);
    assert.notEqual(corrupt.status, 0);
    assert.match(corrupt.text, /integrity mismatch/);
    assert.equal(await fs.readFile(cached, 'utf8'), 'corrupt existing bytes');
  },
);

test(
  'install request cannot proceed with a non-admin token or an unsafe destination',
  { skip: !windows },
  () => {
    // On a non-admin desktop this reaches the privilege guard; on an elevated CI
    // runner the volume-root guard still blocks before any installer can execute.
    const result = invoke('-Install', '-ExternalRoot', path.parse(script).root);
    assert.notEqual(result.status, 0);
    assert.match(result.text, /Administrator PowerShell is required|dedicated directory/);
  },
);
