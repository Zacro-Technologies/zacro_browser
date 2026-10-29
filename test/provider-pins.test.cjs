'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { assertPins, requireNativeCapabilities, readTarMember } = require('./helpers/provider-acceptance.cjs');

test('provider guard rejects a changed version or original archive before managed installation', () => {
  const pin = { version: '1.2.3', sha256: 'a'.repeat(64) };
  assert.doesNotThrow(() => assertPins(pin, '1.2.3', 'a'.repeat(64)));
  assert.throws(() => assertPins(pin, '1.2.4', 'a'.repeat(64)), /pinned version/);
  assert.throws(() => assertPins(pin, '1.2.3', 'b'.repeat(64)), /original SHA-256/);
});

test('demanded custom acceptance cannot pass a stock or incomplete native ABI', () => {
  assert.throws(() => requireNativeCapabilities({ version: 0 }, true), /native ABI/);
  assert.throws(
    () => requireNativeCapabilities({ version: 1, reviewedPermissions: true }, true),
    /activeTab/,
  );
  assert.doesNotThrow(() => requireNativeCapabilities({ version: 0 }, false));
  assert.doesNotThrow(() =>
    requireNativeCapabilities(
      { version: 1, reviewedPermissions: true, activeTab: true, userScripts: true, fontSettings: true },
      true,
    ),
  );
});

test('React fixture extraction rejects truncated or absent UMD members', () => {
  assert.throws(() => readTarMember(Buffer.alloc(512), 'package/umd/react.development.js'), /Missing/);
  const header = Buffer.alloc(512);
  header.write('package/umd/react.development.js');
  header.write('00000000010', 124);
  assert.throws(() => readTarMember(header, 'package/umd/react.development.js'), /Truncated/);
});

test('acquisition guard rejects altered original bytes before extraction or returning a managed download', async () => {
  const { PINS, installAcquisitionGuard } = require('./helpers/provider-acceptance.cjs');
  const packages = {
    ...require('../src/main/extensions/packages.cjs'),
    // Only the external fetch is replaced for this offline guard unit test.
    // Live provider acceptance always invokes the production HTTPS downloader.
    fetchStorePackage: async () => ({
      buffer: Buffer.from('altered original'),
      zip: Buffer.from('not a ZIP'),
      publisherVerified: true,
    }),
  };
  const evidence = [];
  installAcquisitionGuard(packages, evidence);
  await assert.rejects(packages.fetchStorePackage(PINS['dark-reader'].id, {}), /original SHA-256/);
  assert.deepEqual(evidence, []);
});
