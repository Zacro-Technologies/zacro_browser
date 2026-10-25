'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vm = require('node:vm');
const { ExtensionAPI } = require('../src/main/extensions/api.cjs');
const { IdentityController } = require('../src/main/extensions/identity.cjs');
const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
const id = 'a'.repeat(32);
test('native-runtime facade returns synchronous same-ID redirect and Promise/callback lastError', async () => {
  const metadata = { enabled: true, generation: 'g', manifest: {}, grants: { permissions: ['identity'] } };
  const identity = new IdentityController({
    native: {},
    getProfile: () => ({ id: 'p' }),
    resolveExtension: () => metadata,
  });
  const api = new ExtensionAPI({ resolveExtension: () => metadata, identity });
  const context = api.context('p', id);
  const event = () => ({
    addListener() {},
    removeListener() {},
    hasListener() {
      return false;
    },
  });
  const chrome = { runtime: { id, onMessage: event(), onConnect: event() }, tabs: {}, storage: {} };
  vm.runInNewContext(await fs.readFile(path.join(__dirname, '../src/main/extensions/bootstrap.js'), 'utf8'), {
    chrome,
    document: { readyState: 'complete' },
    location: { protocol: 'chrome-extension:', pathname: '/page.html' },
    setTimeout,
    clearTimeout,
    console,
    URL,
    zacroExtension: { onEvent() {}, invoke: (method, args) => api.call(context, method, args) },
  });
  assert.equal(chrome.identity.getRedirectURL('cb?x=1#y'), `https://${id}.chromiumapp.org/cb?x=1#y`);
  assert.throws(() => chrome.identity.getRedirectURL('//evil.test'), /redirect path/);
  assert.deepEqual(await chrome.identity.getProfileUserInfo(), { email: '', id: '' });
  await assert.rejects(chrome.identity.getAuthToken(), /unsupported/);
  const error = await new Promise((resolve) =>
    chrome.identity.getAuthToken({}, () => resolve(chrome.runtime.lastError?.message)),
  );
  assert.match(error, /unsupported/);
  assert.equal(chrome.runtime.lastError, undefined);
  metadata.grants.permissions = [];
  await assert.rejects(chrome.identity.getProfileUserInfo(), /identity permission/);
  await assert.rejects(
    api.call({ ...context, kind: 'content-script' }, 'identity.getProfileUserInfo', []),
    /Trusted/,
  );
});
test('catalog permits web identity while declaring Google oauth2 token service open', () => {
  const manifest = {
    manifest_version: 3,
    name: 'Identity',
    version: '1',
    permissions: ['identity', 'identity.email'],
  };
  assert.equal(inspectManifest(manifest).compatible, true);
  const blocked = inspectManifest({
    ...manifest,
    oauth2: { client_id: 'synthetic.apps.googleusercontent.com', scopes: ['openid'] },
  });
  assert.equal(blocked.compatible, false);
  assert.ok(blocked.unsupported.some((item) => item.capability === 'identity.getAuthToken'));
});
