'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Electron's official installer downloads and checksum-verifies the pinned
// runtime on first use. Reuse that distribution for packaging instead of
// downloading its checksum and archive again on every incremental build.
const executable = require('electron');
const electronRoot = path.dirname(require.resolve('electron/package.json'));
const installed = require('electron/package.json').version;
const expected = require('../package.json').devDependencies.electron;
const runtime = fs
  .readFileSync(path.join(electronRoot, 'dist', 'version'), 'utf8')
  .trim()
  .replace(/^v/, '');
if (installed !== expected || runtime !== expected || !fs.existsSync(executable)) {
  throw new Error('The local Electron runtime does not match the pinned version. Run npm ci and try again.');
}
console.log(`Using pinned Electron ${runtime} for ${process.platform}/${process.arch}.`);
