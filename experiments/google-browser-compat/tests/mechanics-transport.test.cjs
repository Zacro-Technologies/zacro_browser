'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { fixtureTransport } = require('../mechanics.cjs');

const endpoint = 'ws://127.0.0.1:12345/devtools/browser/fixed-fixture-id';
class FixtureSocket extends EventTarget {
  static latest;
  constructor() {
    super();
    FixtureSocket.latest = this;
    this.messages = [];
    queueMicrotask(() => this.dispatchEvent(new Event('open')));
  }
  send(value) {
    this.messages.push(JSON.parse(value));
  }
  close() {
    this.dispatchEvent(new Event('close'));
  }
  receive(value) {
    this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(value) }));
  }
}

test('diagnostic transport rejects remote or credential-bearing endpoints before opening a socket', async () => {
  let opened = 0;
  class ForbiddenSocket {
    constructor() {
      opened++;
    }
  }
  for (const value of [
    'wss://example.test/devtools/browser/fixture',
    'ws://127.0.0.1:12345/not-a-browser',
    `${endpoint}?account=not-retained`,
    `${endpoint}#not-retained`,
    'ws://name:password@127.0.0.1:12345/devtools/browser/fixture',
  ])
    await assert.rejects(fixtureTransport(value, { Socket: ForbiddenSocket }));
  assert.equal(opened, 0);
});

test('diagnostics track pending command names and counts without parameters, results, sessions or errors', async () => {
  let time = 100;
  const transport = await fixtureTransport(endpoint, { Socket: FixtureSocket, now: () => time });
  const socket = FixtureSocket.latest;
  const forwarded = [];
  transport.onmessage = (message) => forwarded.push(message);
  transport.send({
    id: 1,
    method: 'Runtime.evaluate',
    sessionId: 'private-session-id',
    params: { expression: 'private-expression' },
  });
  transport.send({ id: 2, method: 'Runtime.evaluate', params: { expression: 'another-private-expression' } });
  time = 125;
  assert.deepEqual(transport.summary().pending, [{ method: 'Runtime.evaluate', count: 2, oldestMs: 25 }]);
  socket.receive({
    id: 1,
    sessionId: 'private-session-id',
    error: { code: -32000, message: 'private-error-detail' },
  });
  socket.receive({
    method: 'Network.requestWillBeSent',
    params: { url: 'https://example.test/?private-result' },
  });
  socket.receive({ id: 2, result: { privateResult: 'private-result' } });
  assert.equal(forwarded.length, 3);
  assert.deepEqual(transport.summary(), {
    opened: true,
    closed: false,
    sent: 2,
    answered: 2,
    pending: [],
    failed: [{ method: 'Runtime.evaluate', code: -32000 }],
  });
  assert(!JSON.stringify(transport.summary()).includes('private'));
  let closed = 0;
  transport.onclose = () => closed++;
  transport.close();
  transport.close();
  assert.equal(closed, 1);
});

test('a socket that never opens fails within a bounded wait', { timeout: 1000 }, async () => {
  class StalledSocket extends EventTarget {
    close() {
      this.dispatchEvent(new Event('close'));
    }
  }
  await assert.rejects(
    fixtureTransport(endpoint, { Socket: StalledSocket, timeout: 5 }),
    /fixture-websocket-timeout/,
  );
});
