'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { normalizeSiteSearches, siteSearchError, siteSearchURL } = require('../src/core/site-search.js');

test('site searches validate schemes, credentials, placeholder position and bounded unique keywords', () => {
  const valid = { id: 'docs', name: 'Docs', keyword: 'D', url: 'https://example.com/search?q=%s' };
  assert.equal(siteSearchError(valid), '');
  for (const url of [
    'javascript:%s',
    'https://%s.example.com/',
    'https://example.com/#%s',
    'https://user:secret@example.com/?q=%s',
    'https://example.com/?a=%s&b=%s',
    'http://example.com/?q=%s',
  ])
    assert(siteSearchError({ ...valid, url }), url);
  assert.equal(siteSearchError({ ...valid, url: 'http://127.0.0.1:8123/?q=%s' }), '');
  assert.equal(normalizeSiteSearches([valid, { ...valid, keyword: 'd' }]).length, 1);
  assert.equal(normalizeSiteSearches([valid])[0].keyword, 'd');
  assert.equal(
    normalizeSiteSearches(
      Array.from({ length: 30 }, (_, index) => ({ ...valid, id: `s${index}`, keyword: `s${index}` })),
    ).length,
    20,
  );
  assert.deepEqual(normalizeSiteSearches([]), []);
  assert.equal(normalizeSiteSearches(null).length, 3);
});

test('site search queries are encoded once and cannot change the selected origin or query fields', () => {
  const engine = { name: 'Docs', keyword: 'd', url: 'https://example.com/search?q=%s&mode=docs' };
  const url = new URL(siteSearchURL(engine, 'cats & admin=true/#? 日本語'));
  assert.equal(url.origin, 'https://example.com');
  assert.equal(url.searchParams.get('q'), 'cats & admin=true/#? 日本語');
  assert.equal(url.searchParams.get('mode'), 'docs');
  assert.equal(url.searchParams.size, 2);
  assert.equal(url.hash, '');
  assert.throws(() => siteSearchURL(engine, ' '), /Enter a search/);
  assert.throws(() => siteSearchURL(engine, 'a'.repeat(8001)), /Enter a search/);
});

test('current website search prefers an exact-origin configured engine and otherwise scopes the selected search provider', () => {
  const { currentWebsiteSearch } = require('../src/core/site-search.js');
  assert.equal(
    new URL(siteSearchURL(currentWebsiteSearch('https://example.com', []), 'hello')).origin,
    'https://www.google.com',
  );
  const github = currentWebsiteSearch('https://github.com/openai/codex', undefined);
  assert.equal(siteSearchURL(github, 'native views'), 'https://github.com/search?q=native%20views');
  const fallback = currentWebsiteSearch('https://docs.example.com/private?q=secret', [], 'bing');
  const parsed = new URL(siteSearchURL(fallback, 'a & b'));
  assert.equal(parsed.origin, 'https://www.bing.com');
  assert.equal(parsed.searchParams.get('q'), 'site:docs.example.com a & b');
  for (const url of ['file:///tmp/secrets', 'zacro://newtab', 'javascript:alert(1)', 'invalid'])
    assert.equal(currentWebsiteSearch(url, []), null);
});
