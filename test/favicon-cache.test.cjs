'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { SavedFaviconCache } = require('../src/main/favicon-cache.cjs');
const { normalizeRaster } = require('../src/main/favicon.cjs');

const icon = normalizeRaster(
  Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
    'base64',
  ),
);
const url = 'https://saved.test/';
function fixture(t, options) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-favicon-cache-'));
  const cache = new SavedFaviconCache(directory, options);
  t.after(() => {
    cache.flush();
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return { cache, directory };
}
function state(tabs = []) {
  return { profiles: [{ id: 'personal' }, { id: 'work' }, { id: 'private', private: true }], tabs };
}
const pin = (profileId = 'personal', page = url) => ({ profileId, pinned: true, pinnedUrl: page, url: page });

test('saved raster icons survive restart and failed fetches, isolated from other profiles and unsaved pages', (t) => {
  const { cache, directory } = fixture(t);
  const current = state([pin(), { profileId: 'personal', url: 'https://temporary.test/' }, pin('private')]);
  cache.retain(current);
  cache.remember('personal', url, icon);
  cache.remember('private', url, icon);
  cache.remember('personal', 'https://temporary.test/', icon);
  cache.remember('personal', url, null);
  cache.flush();
  assert.equal(fs.readdirSync(cache.directory).length, 1);
  const restarted = new SavedFaviconCache(directory);
  restarted.retain(current);
  assert.equal(restarted.get('personal', url), icon);
  assert.equal(restarted.get('work', url), null);
  assert.equal(restarted.get('private', url), null);
  restarted.clearProfile('personal');
  assert.equal(fs.readdirSync(cache.directory).length, 0);
});

test('saved home and Peek icons remain while referenced and disappear after unpin, close or profile removal', (t) => {
  const { cache } = fixture(t);
  const peekURL = 'https://peek.test/article';
  const awayURL = 'https://saved.test/away';
  const savedTab = { ...pin(), url: awayURL, savedPeek: { url: peekURL } };
  cache.retain(state([savedTab]));
  for (const page of [url, awayURL, peekURL]) cache.remember('personal', page, icon);
  cache.flush();
  cache.retain(state([{ ...savedTab, url }]));
  assert.equal(cache.get('personal', awayURL), null);
  assert.equal(cache.get('personal', url), icon);
  assert.equal(cache.get('personal', peekURL), icon);
  cache.retain(state([{ profileId: 'personal', url, savedPeek: { url: peekURL } }]));
  assert.equal(cache.get('personal', url), null);
  assert.equal(cache.get('personal', peekURL), icon);
  cache.retain(state([]));
  assert.equal(cache.entries.size, 0);
  cache.flush();
  assert.deepEqual(fs.readdirSync(cache.directory), []);
});

test('saved favicon disk input is revalidated and bounded before it reaches the shell', (t) => {
  const { cache, directory } = fixture(t, { maxEntries: 2, maxBytes: 1024 });
  const pages = [url, 'https://saved.test/two', 'https://saved.test/three'];
  cache.retain(state(pages.map((page) => pin('personal', page))));
  cache.remember('personal', url, 'data:image/svg+xml;base64,PHN2Zy8+');
  assert.equal(cache.get('personal', url), null);
  for (const page of pages) cache.remember('personal', page, icon);
  cache.flush();
  assert.equal(cache.entries.size, 2);
  assert(cache.bytes <= 1024);
  assert.equal(
    fs.readdirSync(cache.directory).length,
    3,
    'Memory eviction preserves every saved icon on disk',
  );
  assert.equal(cache.get('personal', url), icon);
  for (const file of fs.readdirSync(cache.directory))
    fs.writeFileSync(path.join(cache.directory, file), '<script>');
  const damaged = new SavedFaviconCache(directory);
  damaged.retain(state(pages.map((page) => pin('personal', page))));
  assert.equal(damaged.get('personal', url), null);
  for (const file of fs.readdirSync(cache.directory))
    fs.writeFileSync(path.join(cache.directory, file), Buffer.alloc(128 * 1024 + 1));
  assert.equal(damaged.get('personal', url), null);
  damaged.flush();
});

test('every saved pin keeps its disk icon after exceeding the memory-cache limit', (t) => {
  const { cache, directory } = fixture(t);
  const pages = Array.from({ length: 150 }, (_, index) => `https://saved.test/${index}`);
  const current = state(pages.map((page) => pin('personal', page)));
  cache.retain(current);
  for (const page of pages) cache.remember('personal', page, icon);
  cache.flush();
  assert.equal(cache.entries.size, 128);
  assert.equal(fs.readdirSync(cache.directory).length, pages.length);
  const restarted = new SavedFaviconCache(directory);
  restarted.retain(current);
  for (const page of pages) assert.equal(restarted.get('personal', page), icon);
  restarted.flush();
});
