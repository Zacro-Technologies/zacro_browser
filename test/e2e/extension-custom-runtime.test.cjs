'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
test(
  'native runtime capability contract, living permissions caller and isolated user scripts',
  { timeout: 90000 },
  async (t) => {
    const required = process.env.ZACRO_REQUIRE_CUSTOM_ELECTRON === '1';
    const executablePath = process.env.ZACRO_CUSTOM_ELECTRON;
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-custom-runtime-'));
    const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const instance = await electron.launch({
      ...(executablePath ? { executablePath } : {}),
      args: [path.resolve(__dirname, '../fixtures/extensions/custom-runtime-host.cjs')],
      env,
    });
    t.after(async () => {
      await instance.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect
      .poll(() => instance.evaluate(() => globalThis.contextResult), { timeout: 70000 })
      .toBeTruthy();
    const result = await instance.evaluate(() => globalThis.contextResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    if (!result.capabilities.reviewedPermissions) {
      assert.equal(required, false, 'Required custom runtime did not negotiate the v1 native ABI');
      assert.equal(result.capabilities.activeTab, false);
      assert.equal(result.capabilities.userScripts, false);
      assert.equal(result.stockDenied, true);
      assert.equal(result.nativeLoaded, false);
      return;
    }
    assert.equal(result.capabilities.activeTab, true);
    assert.equal(result.capabilities.userScripts, true);
    assert.match(result.before.error, /permission|access/i);
    assert.equal(result.active.result[0].result, 'unsaved');
    assert.match(result.sameOriginOther.error, /permission|access/i);
    assert.match(result.afterNavigation.error, /permission|access/i);
    assert.equal(result.permissionRequest, true);
    assert.equal(result.permissionRemoval, true);
    assert.equal(result.originalCaller, true);
    assert.equal(result.generationStable, true);
    assert.equal(result.grantedNetwork, '42');
    assert.equal(result.removedNetwork, false);
    assert.equal(result.draft, 'draft remains');
    assert.equal(result.userScriptsDisabled, true);
    assert.deepEqual(result.worlds, {
      a: 'first',
      b: 'undefined',
      node: 'undefined/undefined',
      credentials: 'undefined/undefined',
    });
    assert.deepEqual(result.restartWorlds, result.worlds);
    assert.equal(result.consentAfterRestart, true);
    assert.equal(result.afterUserScriptsOff, null);
    assert.equal(result.cleanReinstall, true);
    assert.equal(result.noResurrectedScript, true);
    assert.match(result.afterDisable.error, /permission|access|invalid|context|extension|destroy/i);
  },
);
