'use strict';
// Test-only entry point for the real desktop. Substitute only the verified
// package-acquisition boundary with a developer-signed synthetic CRX. The
// production publisher verifier and live provider are tested independently;
// this file is excluded from desktop packaging and adds no production IPC.
const fs = require('node:fs');
const packages = require('../../../src/main/extensions/packages.cjs');
packages.fetchStorePackage = async (id) => {
  const buffer = fs.readFileSync(process.env.ZACRO_FIXTURE_CRX);
  const verified = packages.verifyCrx(buffer, { expectedId: id, requirePublisher: false });
  return { ...verified, buffer, publisherVerified: true, source: { kind: 'chrome-web-store', id } };
};
require('../../../src/main/main.cjs');
