'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'font settings use native preferences for existing/new documents and restore owned defaults',
  { timeout: 45000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-fonts-'));
    const env = { ...process.env, ZACRO_FONT_ROOT: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const required = env.ZACRO_REQUIRE_CUSTOM_ELECTRON === '1';
    let app;
    t.after(async () => {
      await app?.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/font-settings-host.cjs')],
      env,
      ...(env.ZACRO_CUSTOM_ELECTRON ? { executablePath: env.ZACRO_CUSTOM_ELECTRON } : {}),
    });
    await expect
      .poll(() => app.evaluate(() => globalThis.fontSettingsResult), { timeout: 35000 })
      .toBeTruthy();
    const result = await app.evaluate(() => globalThis.fontSettingsResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    if (!result.available) {
      assert.equal(
        required,
        false,
        'Required custom Electron native font runtime is unavailable; this is a failure, not a skip',
      );
      assert.equal(result.denied, true);
      return;
    }
    assert.equal(result.fontListNative, true);
    assert.equal(result.genericMatchesSelected, true);
    assert.equal(result.genericChanged, true);
    assert.equal(result.newDocumentMatches, true);
    assert.equal(result.explicitUnaffected, true);
    assert.equal(result.defaultSize, 31);
    assert.equal(result.fixedSize, 27);
    assert.equal(result.minimumSize, 12);
    assert.equal(result.minimumRenderingChanged, true);
    assert.equal(result.foreignUnchanged, true);
    assert.equal(result.restored, true);
    assert.equal(result.eventReceived, true);
    assert.equal(result.mixedFontEvents, true);
    assert.equal(result.backgroundStopped, true);
    assert.equal(result.backgroundWakeDelivered, true);
    assert.equal(result.disabledRestored, true);
    assert.equal(result.permissionDenied, true);
  },
);
