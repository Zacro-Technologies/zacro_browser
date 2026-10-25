'use strict';
const test = require('node:test'),
  assert = require('node:assert/strict'),
  fs = require('node:fs/promises'),
  path = require('node:path'),
  os = require('node:os');
const { _electron: electron, expect } = require('@playwright/test');
test(
  'custom optional native services preserve caller, wake worker, persist across process restart and revoke on removal',
  { timeout: 90000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-optional-native-'));
    let app;
    t.after(async () => {
      await app?.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    for (const phase of ['register', 'restart']) {
      const env = { ...process.env, ZACRO_OPTIONAL_ROOT: directory, ZACRO_OPTIONAL_PHASE: phase };
      delete env.ELECTRON_RUN_AS_NODE;
      app = await electron.launch({
        args: [path.resolve(__dirname, '../fixtures/extensions/optional-native-services-host.cjs')],
        env,
        ...(env.ZACRO_CUSTOM_ELECTRON ? { executablePath: env.ZACRO_CUSTOM_ELECTRON } : {}),
      });
      await expect.poll(() => app.evaluate(() => globalThis.optionalResult), { timeout: 35000 }).toBeTruthy();
      const result = await app.evaluate(() => globalThis.optionalResult);
      t.diagnostic(JSON.stringify({ phase, ...result }));
      assert.equal(result.error, undefined);
      if (!result.available) {
        assert.notEqual(
          env.ZACRO_REQUIRE_CUSTOM_ELECTRON,
          '1',
          'Required complete native ABI is unavailable',
        );
        return;
      }
      for (const property of phase === 'register'
        ? ['offscreen', 'stopped', 'alarmDelivered', 'originalCaller', 'generationStable']
        : [
            'durable',
            'durableRules',
            'removed',
            'denied',
            'emptyAlarms',
            'emptyRules',
            'noOffscreen',
            'originalCaller',
            'generationStable',
          ])
        assert.equal(result[property], true, property);
      if (phase === 'restart') assert.equal(result.offscreenAfterRestart, false);
      await app.close();
      app = null;
    }
  },
);
