'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { _electron: electron, expect } = require('@playwright/test');
test(
  'reviewed native extension reaches only its synthetic registered host and disconnects on disable',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-e2e-'));
    const env = { ...process.env, ZACRO_NATIVE_MESSAGING_ROOT: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/native-messaging-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect
      .poll(() => app.evaluate(() => globalThis.nativeMessagingResult), { timeout: 30000 })
      .toBeTruthy();
    const result = await app.evaluate(() => globalThis.nativeMessagingResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.equal(result.portSynchronous, true);
    assert.equal(result.localDisconnectEvents, 0);
    assert.equal(result.postClosed, true);
    assert.deepEqual(result.messages, [1, 2]);
    assert.deepEqual(result.promiseResponse, {
      echo: '日本語',
      origin: `chrome-extension://${result.extensionId}/`,
    });
    assert.deepEqual(result.callbackResponse, { callback: true });
    assert.match(result.callbackError, /approval|origin/);
    assert.equal(result.approvals, 2);
    assert.equal(result.callbackLastErrorCleared, true);
    assert.equal(result.sandbox, 'undefined:undefined');
    assert.equal(result.otherDocumentDenied, true);
    assert.equal(result.disabledPorts, 0);
    assert.equal(result.disableDisconnected, true);
    assert.equal(result.closedChildren, true);
  },
);
