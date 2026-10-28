'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const filename = path.resolve(__dirname, '../build/native-source.cjs');
const nativeRequire = createRequire(filename);

function harness(platform, statfs = async () => ({ bavail: 100, bsize: 1024 ** 3 })) {
  let now = 0,
    nextTimer = 1;
  const scheduled = new Map(),
    calls = [],
    signals = [];
  const fakeProcess = new EventEmitter();
  Object.assign(fakeProcess, {
    platform,
    env: {},
    kill(pid, signal) {
      signals.push({ pid, signal });
      return true;
    },
  });
  function makeChild(pid) {
    return Object.assign(new EventEmitter(), {
      pid,
      stdout: new PassThrough(),
      stderr: new PassThrough(),
      killedWith: [],
      unrefCount: 0,
      kill(signal) {
        this.killedWith.push(signal);
        return true;
      },
      unref() {
        this.unrefCount += 1;
      },
    });
  }
  const setTimer = (callback, delay, recurring = false) => {
    const id = nextTimer++;
    scheduled.set(id, { callback, due: now + delay, delay, recurring });
    return id;
  };
  const clearTimer = (id) => scheduled.delete(id);
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module,
    exports: module.exports,
    require(id) {
      if (id === 'node:fs/promises') return { statfs };
      if (id === 'node:child_process')
        return {
          spawn(program, args, options) {
            const child = makeChild(4100 + calls.length);
            calls.push({ program, args: Array.from(args), options, child });
            return child;
          },
        };
      return nativeRequire(id);
    },
    process: fakeProcess,
    setTimeout: (callback, delay) => setTimer(callback, delay),
    clearTimeout: clearTimer,
    setInterval: (callback, delay) => setTimer(callback, delay, true),
    clearInterval: clearTimer,
  });
  const flush = async () => {
    await Promise.resolve();
    await Promise.resolve();
  };
  async function advance(milliseconds) {
    const end = now + milliseconds;
    while (true) {
      const pending = [...scheduled.entries()]
        .filter(([, timer]) => timer.due <= end)
        .sort((a, b) => a[1].due - b[1].due)[0];
      if (!pending) break;
      const [id, timer] = pending;
      now = timer.due;
      if (timer.recurring) timer.due += timer.delay;
      else scheduled.delete(id);
      timer.callback();
      await flush();
    }
    now = end;
    await flush();
  }
  return { execute: module.exports.execute, process: fakeProcess, calls, signals, scheduled, advance, flush };
}

test('POSIX interruption terminates the owned group after its leader exits and ignores repeat signals', async () => {
  const h = harness('darwin');
  const result = h.execute('python', ['gclient.py'], { detached: false });
  const rejected = assert.rejects(result, /interrupted by SIGINT/);
  const child = h.calls[0].child;
  assert.equal(h.calls[0].options.detached, true);
  h.process.emit('SIGINT');
  h.process.emit('SIGINT');
  h.process.emit('SIGTERM');
  assert.deepEqual(h.signals, [{ pid: -child.pid, signal: 'SIGTERM' }]);
  child.emit('exit', 0, null);
  child.emit('close', 0, null);
  await h.advance(1499);
  assert.equal(h.signals.length, 1);
  await h.advance(501);
  await rejected;
  assert.deepEqual(h.signals, [
    { pid: -child.pid, signal: 'SIGTERM' },
    { pid: -child.pid, signal: 'SIGKILL' },
  ]);
  assert.equal(h.calls.length, 1);
  assert.equal(h.scheduled.size, 0);
  assert.equal(h.process.listenerCount('SIGINT'), 0);
  assert.equal(h.process.listenerCount('SIGTERM'), 0);
});

test('reserve checks retain the 15 GiB threshold and fail closed when disk status is unavailable', async () => {
  for (const unavailable of [false, true]) {
    const h = harness('darwin', async () => {
      if (unavailable) throw new Error('disk status unavailable');
      return { bavail: 15 * 1024 ** 3 - 1, bsize: 1 };
    });
    const rejected = assert.rejects(h.execute('clang', [], { diskRoot: '/owned-source' }), /15 GiB/);
    await h.advance(12000);
    await rejected;
    assert.deepEqual(
      h.signals.map((entry) => entry.signal),
      ['SIGTERM', 'SIGKILL'],
    );
  }
  const enough = harness('darwin', async () => ({ bavail: 15 * 1024 ** 3, bsize: 1 }));
  const result = enough.execute('clang', [], { diskRoot: '/owned-source' });
  await enough.advance(10000);
  assert.equal(enough.signals.length, 0);
  enough.calls[0].child.emit('close', 0, null);
  assert.equal(await result, '');
});

test('late disk results cannot signal an already completed command', async () => {
  let report;
  const h = harness('darwin', () => new Promise((resolve) => (report = resolve)));
  const result = h.execute('git', [], { diskRoot: '/owned-source', capture: true });
  await h.advance(10000);
  h.calls[0].child.stdout.write('done\n');
  h.calls[0].child.emit('exit', 0, null);
  h.calls[0].child.emit('close', 0, null);
  assert.equal(await result, 'done');
  report({ bavail: 0, bsize: 4096 });
  await h.flush();
  assert.equal(h.signals.length, 0);
  assert.equal(h.scheduled.size, 0);
});

test('Windows interruption uses exactly one PID tree kill and bounds a hung helper', async () => {
  const h = harness('win32');
  const rejected = assert.rejects(h.execute('python.exe', []), /taskkill exceeded its five-second deadline/);
  const child = h.calls[0].child;
  assert.equal(h.calls[0].options.detached, false);
  h.process.emit('SIGTERM');
  h.process.emit('SIGTERM');
  h.process.emit('SIGINT');
  assert.equal(h.calls.length, 2);
  const helper = h.calls[1];
  assert.equal(path.basename(helper.program), 'taskkill.exe');
  assert.deepEqual(helper.args, ['/PID', String(child.pid), '/T', '/F']);
  await h.advance(5500);
  await rejected;
  assert.deepEqual(helper.child.killedWith, ['SIGKILL']);
  assert.deepEqual(child.killedWith, ['SIGKILL']);
  assert.equal(child.unrefCount, 1);
  assert.equal(h.scheduled.size, 0);
  assert.equal(h.calls.length, 2);
});

test('Windows tree cleanup cancels helper timeout and handles spawn failure', async () => {
  for (const failed of [false, true]) {
    const h = harness('win32');
    const rejected = assert.rejects(h.execute('git.exe', []), failed ? /ENOENT/ : /interrupted by SIGINT/);
    h.process.emit('SIGINT');
    if (failed) h.calls[1].child.emit('error', Object.assign(new Error('missing'), { code: 'ENOENT' }));
    else h.calls[1].child.emit('exit', 0);
    await h.advance(5500);
    await rejected;
    assert.deepEqual(h.calls[1].child.killedWith, []);
    assert.equal(h.scheduled.size, 0);
  }
});

test('a missing POSIX group is never signaled again and spawn failures remove handlers', async () => {
  const h = harness('darwin');
  h.process.kill = () => {
    throw Object.assign(new Error('gone'), { code: 'ESRCH' });
  };
  const rejected = assert.rejects(h.execute('git', []), /interrupted by SIGINT/);
  h.process.emit('SIGINT');
  await h.advance(500);
  await rejected;
  assert.equal(h.scheduled.size, 0);
  const failed = harness('darwin');
  const failure = assert.rejects(failed.execute('missing', [], { diskRoot: '/owned-source' }), /ENOENT/);
  failed.calls[0].child.emit('error', new Error('ENOENT'));
  await failure;
  assert.equal(failed.scheduled.size, 0);
  assert.equal(failed.process.listenerCount('SIGINT'), 0);
});

test('real harmless Node process captures output and exits without leaving signal handlers', async () => {
  const { execute } = require('../build/native-source.cjs');
  const before = ['SIGINT', 'SIGTERM'].map((signal) => process.listenerCount(signal));
  assert.equal(
    await execute(process.execPath, ['-e', 'process.stdout.write("native-process-ok")'], { capture: true }),
    'native-process-ok',
  );
  assert.deepEqual(
    ['SIGINT', 'SIGTERM'].map((signal) => process.listenerCount(signal)),
    before,
  );
});
