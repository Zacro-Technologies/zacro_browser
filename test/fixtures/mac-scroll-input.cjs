'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function buildMacScrollInput() {
  const output = path.resolve(__dirname, '../../.tmp/mac-scroll-input.node');
  const source = path.join(__dirname, 'mac-scroll-input.mm');
  if (fs.existsSync(output) && fs.statSync(output).mtimeMs >= fs.statSync(source).mtimeMs) return output;
  const headers = [
    path.resolve(path.dirname(process.execPath), '../include/node'),
    '/opt/homebrew/include/node',
    '/usr/local/include/node',
  ].find((directory) => fs.existsSync(path.join(directory, 'node_api.h')));
  if (!headers) throw new Error('Native scroll acceptance needs local Node-API headers.');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  execFileSync('xcrun', [
    'clang++',
    '-std=c++17',
    '-fobjc-arc',
    '-mmacosx-version-min=13.0',
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
    output,
  ]);
  return output;
}

module.exports = { buildMacScrollInput };
