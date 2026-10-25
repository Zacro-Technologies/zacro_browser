'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  os = require('node:os'),
  path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');
for (const capability of ['activeTab', 'brokerFailure', 'lazy', 'idleRace'])
  test(`native capability boundary: ${capability}`, { timeout: 65000 }, async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-capability-'));
    const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory, ZACRO_CAPABILITY: capability };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/capability-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect.poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 50000 }).toBeTruthy();
    const result = await app.evaluate(() => globalThis.contextResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    if (capability === 'activeTab') {
      assert.equal(result.adapterAllowed, false);
      assert.match(result.result.error, /permission|access/i);
    } else if (capability === 'brokerFailure') {
      assert.match(result.errorMessage, /transport unavailable/);
      assert.equal(result.calls, 0);
      assert.equal(result.brokerCount, 0);
      assert.equal(result.pageCapability, 'undefined');
    } else if (capability === 'idleRace') {
      assert.deepEqual(
        result.adapterEvents,
        [['idle-race', 1]],
        'event at Port retirement must be delivered once',
      );
    } else {
      assert.equal(result.results.length, 2);
      assert.equal(result.results[0].backgroundsAfterIdle, 0);
      assert.equal(result.results[0].wake.starts, 2);
      assert.equal(result.results[1].backgroundsAfterIdle, 0, 'adapted event page must actually suspend');
      assert.deepEqual(
        result.adapterEvents,
        [['adapter-wake', 2]],
        'host event must wake genuine background exactly once',
      );
      for (const entry of result.results) {
        assert.ok(entry.first);
        assert.ok(entry.wake);
      }
    }
  });
