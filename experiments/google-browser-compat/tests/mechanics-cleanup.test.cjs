'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { closeFixtureSession, installFixtureSignals } = require('../mechanics.cjs');
const never = () => new Promise(() => {});

function fixtureChild() {
  let finish;
  const exited = new Promise((resolve) => (finish = resolve));
  const child = { pid: 12345, exitCode: null, signalCode: null };
  return {
    child,
    exited,
    finish() {
      child.exitCode = 0;
      finish();
    },
  };
}

test(
  'a hung CDP close still reaches the owned Windows child fallback within its deadline',
  { timeout: 1000 },
  async () => {
    const current = fixtureChild();
    const requests = [];
    current.cdp = {
      send: (method) => {
        requests.push(method);
        return never();
      },
    };
    current.browser = {
      close: () => {
        throw new Error('CDP has not settled');
      },
    };
    await closeFixtureSession(current, {
      platform: 'win32',
      gracefulMs: 5,
      terminateMs: 20,
      execute: async (...args) => {
        requests.push(args);
        current.finish();
      },
    });
    assert.deepEqual(requests, [
      'Browser.close',
      ['taskkill', ['/PID', '12345', '/T', '/F'], { windowsHide: true, timeout: 20 }],
    ]);
  },
);

test('graceful exit does not invoke forced process termination', { timeout: 1000 }, async () => {
  const current = fixtureChild();
  const requests = [];
  current.cdp = {
    send: async () => {
      requests.push('graceful');
      current.finish();
    },
  };
  current.browser = { close: async () => requests.push('disconnect') };
  await closeFixtureSession(current, {
    gracefulMs: 10,
    terminateMs: 10,
    execute: async () => assert.fail('must not terminate an exited child'),
  });
  await Promise.resolve();
  assert(requests.includes('graceful'));
  assert.equal(current.child.exitCode, 0);
});

test(
  'Mac fallback targets its child object and a hung termination helper stays bounded',
  { timeout: 1000 },
  async () => {
    const current = fixtureChild();
    const signals = [];
    current.cdp = { send: never };
    current.child.kill = (signal) => {
      signals.push(signal);
      current.finish();
    };
    await closeFixtureSession(current, { platform: 'darwin', gracefulMs: 5, terminateMs: 5 });
    assert.deepEqual(signals, ['SIGKILL']);
    const stuck = fixtureChild();
    await assert.rejects(
      closeFixtureSession(stuck, {
        platform: 'win32',
        gracefulMs: 5,
        terminateMs: 5,
        execute: never,
      }),
      /fixture-child-did-not-exit/,
    );
  },
);

test('a failed spawn never passes an absent PID to process termination', { timeout: 1000 }, async () => {
  await closeFixtureSession(
    { child: { pid: undefined, exitCode: null, signalCode: null }, exited: Promise.resolve() },
    { execute: async () => assert.fail('must not terminate without an owned PID') },
  );
});

test('SIGINT and SIGTERM wait for one cleanup before exiting and can be detached', async () => {
  for (const [signal, code] of [
    ['SIGINT', 130],
    ['SIGTERM', 143],
  ]) {
    const owner = new EventEmitter();
    const exits = [];
    owner.exit = (value) => exits.push(value);
    let finish;
    let calls = 0;
    const hook = installFixtureSignals(() => {
      calls++;
      return new Promise((resolve) => (finish = resolve));
    }, owner);
    owner.emit(signal);
    owner.emit(signal === 'SIGINT' ? 'SIGTERM' : 'SIGINT');
    assert.equal(hook.stopping, true);
    assert.equal(owner.exitCode, code);
    await Promise.resolve();
    assert.equal(calls, 1);
    assert.deepEqual(exits, []);
    finish();
    await hook.finished;
    assert.deepEqual(exits, [code]);
    hook.dispose();
    assert.equal(owner.listenerCount('SIGINT'), 0);
    assert.equal(owner.listenerCount('SIGTERM'), 0);
  }
});
