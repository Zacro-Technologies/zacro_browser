'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { version } = require('../package.json');
if (process.platform !== 'win32') {
  console.error('The verified release pipeline currently supports Windows only.');
  process.exit(1);
}
if (!process.env.CSC_LINK || !process.env.CSC_KEY_PASSWORD) {
  console.error(
    'Commercial releases require CSC_LINK and CSC_KEY_PASSWORD for code signing. Use npm run dist for an explicitly unsigned local test installer.',
  );
  process.exit(1);
}
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
for (const args of [
  ['run', 'verify'],
  ['run', 'dist'],
  ['run', 'test:package'],
]) {
  const result = spawnSync(npm, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
    env: { ...process.env, CSC_IDENTITY_AUTO_DISCOVERY: 'true' },
  });
  if (result.status !== 0) process.exit(result.status || 1);
}
// A configured credential is not proof that the produced files were signed.
// Verify both distribution surfaces with Windows' trust validation before a
// release command can report success. Paths travel as data, never shell code.
const signatureCheck = spawnSync(
  'powershell.exe',
  [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "$ErrorActionPreference = 'Stop'; foreach ($target in @($env:ZACRO_RELEASE_APP, $env:ZACRO_RELEASE_INSTALLER)) { $signature = Get-AuthenticodeSignature -LiteralPath $target; if ($signature.Status -ne 'Valid') { Write-Error ('Release signature is not trusted: ' + [System.IO.Path]::GetFileName($target)); exit 1 }; Write-Output ('Verified publisher signature: ' + [System.IO.Path]::GetFileName($target)) }",
  ],
  {
    stdio: 'inherit',
    windowsHide: true,
    env: {
      ...process.env,
      ZACRO_RELEASE_APP: path.resolve(__dirname, '../dist/win-unpacked/Zacro.exe'),
      ZACRO_RELEASE_INSTALLER: path.resolve(__dirname, `../dist/Zacro-${version}-x64-Setup.exe`),
    },
  },
);
if (signatureCheck.status !== 0) process.exit(signatureCheck.status || 1);
