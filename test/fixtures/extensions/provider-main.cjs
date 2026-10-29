'use strict';
// Launch the real app with a fail-closed test-process pin guard around the real downloader.
const path = require('node:path');
const root = path.resolve(__dirname, '../../..');
globalThis.providerAcquisitions = [];
globalThis.providerCapabilities = require(
  path.join(root, 'src/main/extensions/engine-capabilities.cjs'),
).negotiateEngineCapabilities;
require('../../helpers/provider-acceptance.cjs').installAcquisitionGuard(
  require(path.join(root, 'src/main/extensions/packages.cjs')),
  globalThis.providerAcquisitions,
);
require(path.join(root, 'src/main/main.cjs'));
