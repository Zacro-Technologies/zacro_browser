'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
const { negotiateEngineCapabilities } = require('../src/main/extensions/engine-capabilities.cjs');
const hooks = () => ({
  getZacroCapabilities: () => ({
    version: 1,
    activeTab: true,
    reviewedPermissions: true,
    userScripts: true,
    fontSettings: true,
  }),
  grantZacroActiveTab() {},
  setZacroReviewedPermissions() {},
  setZacroUserScriptsEnabled() {},
  async resetZacroExtensionState() {},
  setZacroFontPreferences() {},
  getZacroFontPreferences() {
    return {};
  },
  async getZacroFontList() {
    return [];
  },
});
test('stock, throwing, unknown-version and incomplete native contracts fail closed', () => {
  for (const extensions of [
    {},
    {
      getZacroCapabilities() {
        throw Error('bad');
      },
    },
    { ...hooks(), getZacroCapabilities: () => ({ version: 2, activeTab: true }) },
    { ...hooks(), setZacroReviewedPermissions: undefined },
    { ...hooks(), resetZacroExtensionState: undefined },
  ]) {
    const result = negotiateEngineCapabilities({ extensions });
    assert.equal(result.reviewedPermissions, false);
    assert.equal(result.activeTab, false);
    assert.equal(result.userScripts, false);
  }
});
test('only a complete advertised native contract enables pure manifest inspection', () => {
  const capabilities = negotiateEngineCapabilities({ extensions: hooks() });
  const manifest = {
    name: 'Native',
    version: '1',
    manifest_version: 3,
    permissions: ['activeTab', 'userScripts', 'fontSettings'],
  };
  assert.equal(inspectManifest(manifest).compatible, false);
  assert.equal(inspectManifest(manifest, capabilities).compatible, true);
  assert.equal(Object.isFrozen(capabilities), true);
});

test('native user scripts remain unavailable in Manifest V2 declarations', () => {
  const capabilities = negotiateEngineCapabilities({ extensions: hooks() });
  assert.equal(
    inspectManifest(
      { name: 'Old', version: '1', manifest_version: 2, permissions: ['userScripts'] },
      capabilities,
    ).compatible,
    false,
  );
  assert.ok(
    inspectManifest(
      { name: 'Old', version: '1', manifest_version: 2, optional_permissions: ['userScripts'] },
      capabilities,
    ).unsupported.some((item) => item.capability === 'userScripts'),
  );
});
