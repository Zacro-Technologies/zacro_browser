'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron, expect } = require('@playwright/test');

test(
  'managed native root-relative ruleset blocks requests and unloads on disable and removal',
  { timeout: 30000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-root-relative-'));
    const env = { ...process.env, ZACRO_NATIVE_DIRECTORY: directory, ZACRO_NATIVE_PHASE: 'root-relative' };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/native-services-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect
      .poll(() => app.evaluate(() => globalThis.nativeServicesResult), { timeout: 20000 })
      .toBeTruthy();
    const result = await app.evaluate(() => globalThis.nativeServicesResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.equal(result.beforeAllowed, true);
    assert.equal(result.nativePath, '/rulesets/main/static.json');
    assert.equal(result.sourceUnchanged, true);
    assert.deepEqual(result.enabledRulesets, ['static']);
    assert.equal(result.staticBlocked, true);
    assert.equal(result.unmatchedAllowed, true);
    assert.equal(result.otherProfileAllowed, true);
    assert.equal(result.disabledAllowed, true);
    assert.equal(result.reenabledBlocked, true);
    assert.equal(result.removedAllowed, true);
  },
);

test(
  'startup offscreen creation waits for initialization and survives activation',
  { timeout: 30000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-offscreen-startup-'));
    const env = { ...process.env, ZACRO_CONTEXT_ROOT: directory };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/offscreen-startup-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect.poll(() => app.evaluate(() => globalThis.contextResult), { timeout: 20000 }).toBeTruthy();
    const result = await app.evaluate(() => globalThis.contextResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.equal(result.enabled, true);
    assert.equal(
      result.heldBoundary,
      true,
      'the real worker must attempt startup creation before initialization',
    );
    assert.deepEqual(result.after, { result: 'created', has: true });
    assert.equal(result.before, false, 'native document creation must wait behind initialization');
    assert.equal(result.readyRequested, true);
    assert.equal(result.disabledClosed, true);
  },
);

test(
  'managed native update reconciles rulesets and removes offscreen permission',
  { timeout: 30000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-update-'));
    const env = { ...process.env, ZACRO_NATIVE_DIRECTORY: directory, ZACRO_NATIVE_PHASE: 'update' };
    delete env.ELECTRON_RUN_AS_NODE;
    const app = await electron.launch({
      args: [path.resolve(__dirname, '../fixtures/extensions/native-services-host.cjs')],
      env,
    });
    t.after(async () => {
      await app.close();
      await fs.rm(directory, { recursive: true, force: true });
    });
    await expect
      .poll(() => app.evaluate(() => globalThis.nativeServicesResult), { timeout: 20000 })
      .toBeTruthy();
    const result = await app.evaluate(() => globalThis.nativeServicesResult);
    t.diagnostic(JSON.stringify(result));
    assert.equal(result.error, undefined);
    assert.equal(result.version, '2');
    assert.equal(result.enabled, true);
    assert.deepEqual(result.choices, ['new']);
    assert.equal(result.oldAllowed, true);
    assert.equal(result.newBlocked, true);
    assert.equal(result.dynamicBlocked, true);
    assert.equal(result.offscreenPermissionAbsent, 'undefined');
    assert.equal(result.offscreenClosed, true);
    assert.equal(result.forgedAlarmDenied, true);
  },
);

test(
  'managed native rules, offscreen and alarms retain their real boundaries across restart',
  { timeout: 120000 },
  async (t) => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-services-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    for (const phase of ['install', 'restart']) {
      const env = { ...process.env, ZACRO_NATIVE_DIRECTORY: directory, ZACRO_NATIVE_PHASE: phase };
      delete env.ELECTRON_RUN_AS_NODE;
      const app = await electron.launch({
        args: [path.resolve(__dirname, '../fixtures/extensions/native-services-host.cjs')],
        env,
      });
      try {
        await expect
          .poll(() => app.evaluate(() => globalThis.nativeServicesResult), { timeout: 100000 })
          .toBeTruthy();
        const result = await app.evaluate(() => globalThis.nativeServicesResult);
        t.diagnostic(JSON.stringify({ phase, ...result }));
        assert.equal(result.error, undefined);
        if (phase === 'install') {
          assert.equal(result.ordinaryFacade, 'object:object:object');
          assert.equal(result.staticBlocked, true);
          assert.equal(result.cacheDiscarded, true);
          assert.equal(result.dynamicBlocked, true);
          assert.equal(result.sessionBlocked, true);
          assert.equal(result.redirected, '/landed');
          assert.equal(result.header, 'native');
          assert.equal(result.otherProfileAllowed, true);
          assert.equal(result.disabledAllowed, true);
          assert.deepEqual(result.reenabledStatic, []);
          assert.equal(result.reenabledDynamicBlocked, true);
          assert.equal(result.reenabledSessionAllowed, true);
          assert.deepEqual(result.offscreen, {
            title: 'Native offscreen',
            storage: 'undefined',
            tabs: 'undefined',
            bridge: 'undefined',
            node: 'undefined',
            process: 'undefined',
            worker: 'native-worker',
            denied: true,
          });
          assert.equal(result.duplicateRejected, true);
          assert.equal(result.offscreenBadUrlRejected, true);
          assert.equal(result.offscreenClosed, true);
          assert.equal(result.offscreenDisableClosed, true);
          assert.equal(result.privateRejected, true);
          assert.equal(result.alarmSuspended, true);
          assert.equal(result.alarmWake.starts, 2);
          assert.equal(result.alarmWake.name, 'native-wake');
          assert.equal(result.alarmNativeEvents.length, 1);
          assert.equal(result.cleared, true);
          assert.equal(result.alarmCallbacks, true);
        } else {
          assert.equal(result.dynamicBlocked, true);
          assert.equal(result.sessionAllowed, true);
          assert.deepEqual(result.staticChoices, []);
          assert.equal(result.offscreenAbsent, true);
          assert.equal(result.alarmRestored, true);
          assert.equal(result.removedAllowed, true);
        }
      } finally {
        await app.close();
      }
    }
  },
);
