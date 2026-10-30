'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { binaryTarget } = require('./platform-build.cjs');

function buildNativeMac({ force = false } = {}) {
  if (process.platform !== 'darwin') return;
  const root = path.resolve(__dirname, '..');
  const source = path.join(root, 'native/macos-bridge.mm');
  const output = path.join(root, 'src/native/macos-bridge.node');
  if (!force && fs.existsSync(output) && fs.statSync(output).mtimeMs >= fs.statSync(source).mtimeMs) {
    const target = binaryTarget(fs.readFileSync(output).subarray(0, 4096));
    if (target?.platform === 'darwin' && target.arch === process.arch) return output;
  }
  const headers = [
    path.resolve(path.dirname(process.execPath), '../include/node'),
    '/opt/homebrew/include/node',
    '/usr/local/include/node',
  ].find((directory) => fs.existsSync(path.join(directory, 'node_api.h')));
  if (!headers)
    throw new Error('Building the Mac bridge requires Node.js headers from a full Node.js installation.');
  if (!['arm64', 'x64'].includes(process.arch))
    throw new Error(`Unsupported Mac architecture: ${process.arch}`);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const temporary = `${output}.${process.pid}.tmp`;
  try {
    execFileSync(
      'xcrun',
      [
        'clang++',
        '-std=c++17',
        '-fobjc-arc',
        '-mmacosx-version-min=13.0',
        '-arch',
        process.arch === 'x64' ? 'x86_64' : 'arm64',
        '-DNAPI_VERSION=8',
        '-I',
        headers,
        '-bundle',
        '-undefined',
        'dynamic_lookup',
        '-framework',
        'Cocoa',
        source,
        '-o',
        temporary,
      ],
      { stdio: 'inherit' },
    );
    fs.renameSync(temporary, output);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
  console.log(`Built the macOS ${process.arch} input and material bridge.`);
  return output;
}

if (require.main === module) buildNativeMac({ force: true });
module.exports = { buildNativeMac };
