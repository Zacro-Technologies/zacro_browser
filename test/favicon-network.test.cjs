'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { FaviconLoader, MAX_BYTES } = require('../src/main/favicon.cjs');

let server, base;
const requested = new Set(),
  abandoned = new Set();
before(async () => {
  server = http.createServer((request, response) => {
    requested.add(request.url);
    response.once('close', () => {
      if (!response.writableEnded) abandoned.add(request.url);
    });
    if (request.url === '/ready') {
      response.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': 5 });
      response.end('ready');
      return;
    }
    if (request.url === '/stalled') return;
    if (request.url === '/header-limit') {
      response.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': MAX_BYTES + 1 });
      response.flushHeaders();
      return;
    }
    if (request.url === '/wrong-mime') {
      response.writeHead(200, { 'Content-Type': 'image/svg+xml' });
      response.flushHeaders();
      return;
    }
    if (request.url === '/body-limit') {
      response.writeHead(200, { 'Content-Type': 'image/png' });
      response.write(Buffer.alloc(MAX_BYTES + 1));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  // Listening does not initialize Node's lazy native-fetch implementation.
  // Complete a real HTTP exchange before the loader's deliberately short
  // deadline, so cold fetch startup cannot prevent the rejection fixture
  // from receiving its request on a busy CI host.
  const readiness = await fetch(`${base}/ready`, { signal: AbortSignal.timeout(5000) });
  assert.equal(readiness.status, 200);
  assert.equal(await readiness.text(), 'ready');
});
after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

for (const name of ['header-limit', 'wrong-mime', 'body-limit', 'stalled']) {
  test(`favicon ${name} rejection closes a real unfinished HTTP response`, { timeout: 5000 }, async () => {
    const loader = new FaviconLoader({ timeoutMs: 100 });
    const session = { fetch: (...args) => fetch(...args) };
    const result = await loader.load(session, `${base}/page`, [`${base}/${name}`]);
    assert.equal(result, null);
    assert(requested.has(`/${name}`), 'The fixture must exercise an actual HTTP request');
    assert.equal(loader.active, 0, 'Aborted requests must release the concurrency slot');
    const deadline = Date.now() + 1000;
    while (!abandoned.has(`/${name}`) && Date.now() < deadline)
      await new Promise((resolve) => setTimeout(resolve, 10));
    assert(abandoned.has(`/${name}`), 'The HTTP body must close without waiting for the server to finish');
  });
}
