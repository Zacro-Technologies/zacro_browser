'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  assertNativeTarget,
  binaryTarget,
  packagedPaths,
  notarizationCredentials,
} = require('../scripts/platform-build.cjs');

test('packaging rejects cross-platform, cross-architecture and universal runtime mixes', () => {
  assert.doesNotThrow(() => assertNativeTarget('darwin', 'arm64', 'darwin', 'arm64'));
  assert.doesNotThrow(() => assertNativeTarget('darwin', 'x64', 'darwin', 'x64'));
  assert.throws(() => assertNativeTarget('darwin', 'arm64', 'win32', 'arm64'), /matching Node.js host/);
  assert.throws(() => assertNativeTarget('darwin', 'arm64', 'darwin', 'x64'), /matching Node.js host/);
  assert.throws(() => assertNativeTarget('darwin', 'universal', 'darwin', 'arm64'), /separate x64 or arm64/);
});

test('runtime headers identify actual architecture independently of package metadata', () => {
  for (const [cpu, arch] of [
    [0x01000007, 'x64'],
    [0x0100000c, 'arm64'],
  ]) {
    const bytes = Buffer.alloc(256);
    bytes.writeUInt32LE(0xfeedfacf, 0);
    bytes.writeUInt32LE(cpu, 4);
    assert.deepEqual(binaryTarget(bytes), { platform: 'darwin', arch });
  }
  const pe = Buffer.alloc(256);
  pe.write('MZ');
  pe.writeUInt32LE(128, 0x3c);
  pe.write('PE\0\0', 128);
  pe.writeUInt16LE(0x8664, 132);
  assert.deepEqual(binaryTarget(pe), { platform: 'win32', arch: 'x64' });
  pe.writeUInt32LE(1024, 0x3c);
  assert.equal(binaryTarget(pe), null);
  assert.equal(binaryTarget(Buffer.alloc(3)), null);
  assert.equal(binaryTarget(Buffer.alloc(256)), null);
});

test('packaged app paths select the architecture-specific macOS bundle', () => {
  const root = path.resolve('/workspace');
  assert.equal(
    packagedPaths(root, 'darwin', 'arm64').executable,
    path.join(root, 'dist/mac-arm64/Zacro.app/Contents/MacOS/Zacro'),
  );
  assert.equal(
    packagedPaths(root, 'darwin', 'x64').resources,
    path.join(root, 'dist/mac/Zacro.app/Contents/Resources'),
  );
  assert.equal(
    packagedPaths(root, 'win32', 'x64').executable,
    path.join(root, 'dist/win-unpacked/Zacro.exe'),
  );
});

test('release notarization refuses partial credentials and supports an existing keychain profile', () => {
  assert.throws(() => notarizationCredentials({}), /requires Apple notarization/);
  assert.throws(() => notarizationCredentials({ APPLE_ID: 'example.invalid' }), /together/);
  assert.throws(() => notarizationCredentials({ APPLE_API_KEY_ID: 'example' }), /together/);
  assert.deepEqual(notarizationCredentials({ APPLE_KEYCHAIN_PROFILE: 'zacro-release' }), {
    keychainProfile: 'zacro-release',
  });
  assert.deepEqual(
    notarizationCredentials({
      APPLE_API_KEY: '/test/key.p8',
      APPLE_API_KEY_ID: 'test',
      APPLE_API_ISSUER: 'issuer',
    }),
    { appleApiKey: '/test/key.p8', appleApiKeyId: 'test', appleApiIssuer: 'issuer' },
  );
});

test('macOS icon contains intact PNG representations from 16 to 1024 pixels', () => {
  const icon = fs.readFileSync(path.join(__dirname, '../assets/icon.icns'));
  assert.equal(icon.toString('ascii', 0, 4), 'icns');
  assert.equal(icon.readUInt32BE(4), icon.length);
  const expected = new Map([
    ['icp4', 16],
    ['icp5', 32],
    ['icp6', 64],
    ['ic07', 128],
    ['ic08', 256],
    ['ic09', 512],
    ['ic10', 1024],
  ]);
  let offset = 8;
  while (offset < icon.length) {
    const type = icon.toString('ascii', offset, offset + 4);
    const size = icon.readUInt32BE(offset + 4);
    assert(size > 32 && offset + size <= icon.length);
    assert.equal(icon.toString('hex', offset + 8, offset + 16), '89504e470d0a1a0a');
    assert.equal(icon.readUInt32BE(offset + 24), expected.get(type));
    assert.equal(icon.readUInt32BE(offset + 28), expected.get(type));
    expected.delete(type);
    offset += size;
  }
  assert.equal(offset, icon.length);
  assert.equal(expected.size, 0);
});
