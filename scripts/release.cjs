'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const { version } = require('../package.json');
const { packagedPaths, notarizationCredentials } = require('./platform-build.cjs');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: 'inherit', windowsHide: true, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed with status ${result.status}.`);
}
function npm(script) {
  run(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['run', script], {
    shell: process.platform === 'win32',
    env: { ...process.env, CSC_IDENTITY_AUTO_DISCOVERY: 'true' },
  });
}
async function main() {
  if (!['win32', 'darwin'].includes(process.platform))
    throw new Error('Release verification is configured for Windows and macOS.');
  const hasCertificate = process.env.CSC_LINK && process.env.CSC_KEY_PASSWORD;
  if (!hasCertificate && !(process.platform === 'darwin' && process.env.CSC_NAME))
    throw new Error(
      'Releases require CSC_LINK and CSC_KEY_PASSWORD, or an installed macOS Developer ID selected by CSC_NAME. Use the development build command for a local preview.',
    );
  const root = path.resolve(__dirname, '..');
  if (process.platform === 'darwin') {
    // Check configuration before invoking the build or transmitting an artifact.
    const credentials = notarizationCredentials(process.env);
    npm('format:check');
    npm('check');
    run(process.execPath, [
      '--test',
      ...fs
        .readdirSync(path.join(root, 'test'))
        .filter((file) => file.endsWith('.test.cjs'))
        .map((file) => path.join(root, 'test', file)),
    ]);
    npm('test:mac');
    await require('./build-mac.cjs').buildMac({ release: true });
    npm('test:package');
    const { bundle, resources } = packagedPaths(root);
    run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle]);
    run('spctl', ['--assess', '--type', 'execute', '--verbose=2', bundle]);
    run('xcrun', ['stapler', 'validate', bundle]);
    const triple = process.arch === 'arm64' ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin';
    const codex = path.join(
      resources,
      'app.asar.unpacked/node_modules',
      `@openai/codex-darwin-${process.arch}`,
      'vendor',
      triple,
      'bin/codex',
    );
    run('codesign', ['--verify', '--strict', '--verbose=2', codex]);
    const dmg = path.join(root, 'dist', `Zacro-${version}-mac-${process.arch}.dmg`);
    // The app's ticket is already inside both archives. Notarize and staple the
    // DMG too, so Gatekeeper can validate the download itself while offline.
    await require('@electron/notarize').notarize({ appPath: dmg, ...credentials });
    run('codesign', ['--verify', '--strict', '--verbose=2', dmg]);
    run('xcrun', ['stapler', 'validate', dmg]);
    run('spctl', [
      '--assess',
      '--type',
      'open',
      '--context',
      'context:primary-signature',
      '--verbose=2',
      dmg,
    ]);
    return;
  }
  npm('verify');
  npm('dist');
  npm('test:package');
  // A configured credential is not proof of a trusted publisher signature.
  // Paths travel as environment data, never interpolated PowerShell code.
  run(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "$ErrorActionPreference = 'Stop'; foreach ($target in @($env:ZACRO_RELEASE_APP, $env:ZACRO_RELEASE_INSTALLER)) { $signature = Get-AuthenticodeSignature -LiteralPath $target; if ($signature.Status -ne 'Valid') { Write-Error ('Release signature is not trusted: ' + [System.IO.Path]::GetFileName($target)); exit 1 }; Write-Output ('Verified publisher signature: ' + [System.IO.Path]::GetFileName($target)) }",
    ],
    {
      env: {
        ...process.env,
        ZACRO_RELEASE_APP: packagedPaths(root).executable,
        ZACRO_RELEASE_INSTALLER: path.join(root, 'dist', `Zacro-${version}-x64-Setup.exe`),
      },
    },
  );
}
main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
