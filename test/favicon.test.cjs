'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { FaviconLoader, normalizeRaster, MAX_BYTES } = require('../src/main/favicon.cjs');

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
  'base64',
);

function bitmapIcon() {
  const bytes = Buffer.alloc(22 + 40 + 32 * 32 * 4 + 32 * 4);
  bytes.writeUInt16LE(1, 2);
  bytes.writeUInt16LE(1, 4);
  bytes[6] = bytes[7] = 32;
  bytes.writeUInt16LE(1, 10);
  bytes.writeUInt16LE(32, 12);
  bytes.writeUInt32LE(bytes.length - 22, 14);
  bytes.writeUInt32LE(22, 18);
  bytes.writeUInt32LE(40, 22);
  bytes.writeInt32LE(32, 26);
  bytes.writeInt32LE(64, 30);
  bytes.writeUInt16LE(1, 34);
  bytes.writeUInt16LE(32, 36);
  return bytes;
}

function response(bytes = PNG, mime = 'image/png') {
  return new Response(bytes, { status: 200, headers: { 'content-type': mime } });
}

test('favicons admit bounded PNG and simple ICO pixels, excluding active and oversized formats', () => {
  assert.match(normalizeRaster(PNG), /^data:image\/png;base64,/);
  assert.match(normalizeRaster(bitmapIcon()), /^data:image\/x-icon;base64,/);
  assert.equal(normalizeRaster(Buffer.from('<svg onload="alert(1)"></svg>')), null);
  assert.equal(normalizeRaster(Buffer.alloc(MAX_BYTES + 1)), null);
  assert.equal(normalizeRaster(PNG.subarray(0, 36)), null);
  const giantPNG = Buffer.from(PNG);
  giantPNG.writeUInt32BE(1_000_000, 16);
  assert.equal(normalizeRaster(giantPNG), null);
  const badICO = bitmapIcon();
  badICO.writeInt32LE(1_000_000, 26);
  assert.equal(normalizeRaster(badICO), null);
  const overlappingICO = bitmapIcon();
  overlappingICO.writeUInt32LE(6, 18);
  assert.equal(normalizeRaster(overlappingICO), null);
});

test('favicon caches are confined to their originating Chromium session', async () => {
  const loader = new FaviconLoader();
  let firstCount = 0;
  let secondCount = 0;
  const first = {
    fetch: async () => {
      firstCount++;
      return response();
    },
  };
  const second = {
    fetch: async () => {
      secondCount++;
      return response();
    },
  };
  const firstResult = await loader.load(first, 'https://site.test/a', ['https://site.test/icon.png']);
  await loader.load(first, 'https://site.test/b', ['https://site.test/icon.png']);
  await loader.load(second, 'https://site.test/a', ['https://site.test/icon.png']);
  assert.match(firstResult, /^data:image\/png/);
  assert.equal(firstCount, 1);
  assert.equal(secondCount, 1);
});

test('favicon retrieval rejects other origins, embedded credentials, redirect responses and executable content', async () => {
  const loader = new FaviconLoader();
  const calls = [];
  const session = {
    fetch: async (url, options) => {
      calls.push(url);
      assert.equal(options.redirect, 'error');
      if (url.endsWith('/redirect.ico'))
        return new Response(null, { status: 302, headers: { location: 'http://127.0.0.1/private' } });
      return response(Buffer.from('<svg></svg>'), 'image/svg+xml');
    },
  };
  assert.equal(
    await loader.load(session, 'https://site.test/', [
      'http://127.0.0.1/private',
      'file:///sensitive.ico',
      'https://user:pass@site.test/icon.ico',
      'https://site.test/redirect.ico',
    ]),
    null,
  );
  assert.deepEqual(calls, ['https://site.test/redirect.ico', 'https://site.test/favicon.ico']);
  assert.equal(await loader.load(session, 'file:///private', []), null);
});

test('favicon size limits apply to streamed bodies without trustworthy length headers', async () => {
  let cancelled = 0;
  const loader = new FaviconLoader();
  const session = {
    fetch: async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(new Uint8Array(MAX_BYTES));
            controller.enqueue(new Uint8Array(1));
          },
          cancel() {
            cancelled++;
          },
        }),
        { headers: { 'content-type': 'image/png' } },
      ),
  };
  assert.equal(await loader.load(session, 'https://site.test/', ['https://site.test/icon.png']), null);
  assert.equal(cancelled, 2);
  assert.equal(loader.active, 0);
});

test('favicon navigation cancellation prevents stale cache insertion and releases concurrent work', async () => {
  const loader = new FaviconLoader();
  const controller = new AbortController();
  let started;
  const ready = new Promise((resolve) => {
    started = resolve;
  });
  const session = {
    fetch: async (_url, { signal }) => {
      started();
      await new Promise((_resolve, reject) =>
        signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }),
      );
    },
  };
  const pending = loader.load(session, 'https://site.test/', [], { signal: controller.signal });
  await ready;
  controller.abort();
  assert.equal(await pending, null);
  assert.equal(loader.active, 0);
  assert.equal(loader.cache.get(session).size, 0);
});

test('favicon failures are cached briefly rather than refetched on every page update', async () => {
  const loader = new FaviconLoader();
  let count = 0;
  const session = {
    fetch: async () => {
      count++;
      return new Response(null, { status: 404 });
    },
  };
  await loader.load(session, 'https://site.test/a');
  await loader.load(session, 'https://site.test/a');
  assert.equal(count, 1);
});

test('clearing browsing data invalidates cached icons and pending results in that session', async () => {
  const loader = new FaviconLoader();
  let release;
  let count = 0;
  const session = {
    fetch: async () => {
      count++;
      if (count === 1)
        await new Promise((resolve) => {
          release = resolve;
        });
      return response();
    },
  };
  const pending = loader.load(session, 'https://site.test/');
  loader.clear(session);
  release();
  assert.equal(await pending, null);
  assert.equal(loader.cache.get(session), undefined);
  assert.match(await loader.load(session, 'https://site.test/'), /^data:image\/png/);
  loader.clear(session);
  assert.match(await loader.load(session, 'https://site.test/'), /^data:image\/png/);
  assert.equal(count, 3);
});
