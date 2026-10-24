'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { assertNativeTarget, binaryTarget } = require('./platform-build.cjs');
const { executablePath } = require('../src/main/codex.cjs');

// Electron's official installer downloads and checksum-verifies the pinned
// runtime on first use. Reuse that distribution for packaging instead of
// downloading its checksum and archive again on every incremental build.
function validateRuntime(platform = process.platform, arch = process.arch) {
  assertNativeTarget(platform, arch);
  const executable = require('electron');
  const electronRoot = path.dirname(require.resolve('electron/package.json'));
  const installed = require('electron/package.json').version;
  const expected = require('../package.json').devDependencies.electron;
  const runtime = fs
    .readFileSync(path.join(electronRoot, 'dist', 'version'), 'utf8')
    .trim()
    .replace(/^v/, '');
  if (installed !== expected || runtime !== expected || !fs.existsSync(executable))
    throw new Error(
      'The local Electron runtime does not match the pinned version. Run npm ci and try again.',
    );
  const codex = executablePath(platform, arch);
  for (const [name, file] of [
    ['Electron', executable],
    ['Codex', codex],
  ]) {
    if (!file)
      throw new Error(`The ${platform}/${arch} ${name} runtime is missing. Run npm ci on this host.`);
    const descriptor = fs.openSync(file, 'r');
    const header = Buffer.alloc(4096);
    try {
      fs.readSync(descriptor, header, 0, header.length, 0);
    } finally {
      fs.closeSync(descriptor);
    }
    const target = binaryTarget(header);
    if (target?.platform !== platform || target?.arch !== arch)
      throw new Error(`${name} has the wrong binary architecture. Run npm ci with native ${arch} Node.js.`);
  }
  console.log(`Using pinned Electron ${runtime} and Codex for ${platform}/${arch}.`);
}
if (require.main === module) validateRuntime();
module.exports = { validateRuntime };
