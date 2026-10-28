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

function markHidden(directory) {
  const result = spawnSync(
    'powershell.exe',
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "$ErrorActionPreference = 'Stop'; $item = Get-Item -LiteralPath $env:ZACRO_TEST_HIDDEN_DIRECTORY -Force; $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden; if (-not ((Get-Item -LiteralPath $env:ZACRO_TEST_HIDDEN_DIRECTORY -Force).Attributes -band [IO.FileAttributes]::Hidden)) { throw 'Hidden fixture attribute was not applied.' }",
    ],
    {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 15000,
      env: { ...process.env, ZACRO_TEST_HIDDEN_DIRECTORY: directory },
    },
  );
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
}

function invokeProvisionFunctions(body) {
  // Load only these pure function declarations from the real script's AST.
  // The script body, downloads, privilege handling and installers never run.
  const setup = `
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $parseTokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($env:ZACRO_TEST_PROVISION_SCRIPT, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Provisioning script failed syntax validation.' }
    $names = @('Get-ZacroInstallerSpecifications', 'Select-ZacroQualifiedCompiler', 'Assert-ZacroPreservedInstances')
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $node.Name }, $false))
    if ($functions.Count -ne $names.Count) { throw 'Expected provisioning guards were not found.' }
    foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
    ${body}
  `;
  const result = spawnSync(
    'powershell.exe',
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', setup],
    {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 15000,
      env: {
        ...process.env,
        ZACRO_TEST_PROVISION_SCRIPT: script,
        ZACRO_TEST_INSTALLER_MANIFEST: path.join(path.dirname(script), 'windows-installers.lock.json'),
      },
    },
  );
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return JSON.parse(result.stdout);
}

test(
  'SDK-only selection retains the SDK pin and excludes Visual Studio in every mode',
  { skip: !windows },
  () => {
    const result = invokeProvisionFunctions(`
    $manifest = Get-Content -LiteralPath $env:ZACRO_TEST_INSTALLER_MANIFEST -Raw | ConvertFrom-Json
    $full = @(Get-ZacroInstallerSpecifications $manifest $false)
    $sdk = @(Get-ZacroInstallerSpecifications $manifest $true)
    [ordered]@{ full=@($full.id); sdk=@($sdk.id); sdkSha256=$sdk[0].sha256; originalCount=$manifest.installers.Count } | ConvertTo-Json -Compress
  `);
    assert.deepEqual(result.full, ['visual-studio', 'windows-sdk']);
    assert.deepEqual(result.sdk, ['windows-sdk']);
    assert.equal(result.sdkSha256, manifest.installers.find((entry) => entry.id === 'windows-sdk').sha256);
    assert.equal(result.originalCount, 2);
  },
);

test(
  'SDK-only compiler qualification requires a complete VS18+ and preserves all existing instances',
  { skip: !windows },
  () => {
    const result = invokeProvisionFunctions(`
    $old = [pscustomobject]@{ instanceId='old'; installationVersion='17.12.0.0'; installationPath='C:\\FixtureVS17'; isComplete=$true; isLaunchable=$true }
    $current = [pscustomobject]@{ instanceId='current'; installationVersion='18.11.12315.225'; installationPath='C:\\FixtureVS18'; isComplete=$true; isLaunchable=$true }
    $incomplete = [pscustomobject]@{ instanceId='incomplete'; installationVersion='19.0.0.0'; installationPath='C:\\FixtureVS19'; isComplete=$false; isLaunchable=$true }
    $selected = Select-ZacroQualifiedCompiler @($old, $current, $incomplete)
    $rejected = 0
    foreach ($invalid in @(@(), @($old), @($incomplete))) {
      try { Select-ZacroQualifiedCompiler $invalid | Out-Null } catch { $rejected++ }
    }
    Assert-ZacroPreservedInstances @($old, $current) @($old, $current)
    $changedVersion = [pscustomobject]@{ instanceId='current'; installationVersion='18.12.0.0'; installationPath=$current.installationPath }
    $changedPath = [pscustomobject]@{ instanceId='current'; installationVersion=$current.installationVersion; installationPath='C:\\ChangedVS18' }
    $preservationRejected = 0
    foreach ($changed in @($changedVersion, $changedPath)) {
      try { Assert-ZacroPreservedInstances @($old, $current) @($old, $changed) } catch { $preservationRejected++ }
    }
    [ordered]@{ selected=$selected.instanceId; rejected=$rejected; preservationRejected=$preservationRejected } | ConvertTo-Json -Compress
  `);
    assert.equal(result.selected, 'current');
    assert.equal(result.rejected, 3);
    assert.equal(result.preservationRejected, 2);
  },
);

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

test('hidden ancestors remain usable while nested junctions are rejected', { skip: !windows }, async (t) => {
  const directory = await scratch(t),
    hidden = path.join(directory, 'hidden-parent'),
    root = path.join(hidden, 'owned');
  await fs.mkdir(hidden);
  markHidden(hidden);
  // Reproduces AppData on hosted Windows runners without modifying AppData or
  // requiring any cached installer, download, elevation, or installed toolchain.
  const missing = invoke('-ExternalRoot', root);
  assert.notEqual(missing.status, 0);
  assert.match(missing.text, /Run this script with -Download first/);
  const owner = JSON.parse(await fs.readFile(path.join(root, '.zacro-native-toolchain.json'), 'utf8'));
  assert.equal(owner.schemaVersion, 1);
  assert.equal(owner.kind, 'zacro-native-toolchain');
  assert.equal(await fs.realpath(owner.root), await fs.realpath(root));

  const foreign = path.join(directory, 'foreign'),
    junction = path.join(hidden, 'redirect');
  await fs.mkdir(foreign);
  await fs.symlink(foreign, junction, 'junction');
  const redirected = invoke('-ExternalRoot', path.join(junction, 'new-cache'));
  assert.notEqual(redirected.status, 0);
  assert.match(redirected.text, /junction or symbolic link/);
  await assert.rejects(fs.access(path.join(foreign, 'new-cache')), { code: 'ENOENT' });
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
    assert.equal(owner.schemaVersion, 1);
    assert.equal(owner.kind, 'zacro-native-toolchain');
    assert.equal(await fs.realpath(owner.root), await fs.realpath(root));
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
    const sdkOnly = invoke('-Install', '-SdkOnly', '-ExternalRoot', path.parse(script).root);
    assert.notEqual(sdkOnly.status, 0);
    assert.match(sdkOnly.text, /Administrator PowerShell is required|dedicated directory/);
  },
);
