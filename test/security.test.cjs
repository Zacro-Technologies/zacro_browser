'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { webURL, safeFilename, unusedPath, renameWithoutOverwrite } = require('../src/main/security.cjs');
const {
  BrowserStore,
  createInitialState,
  hydrate,
  normalizeAddress,
  validateSettings,
} = require('../src/core/store.cjs');
const { parseBookmarksHtml } = require('../src/core/import.cjs');

async function tempDirectory(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-security-'));
  t.after(() => fs.rm(directory, { force: true, recursive: true }));
  return directory;
}

test('external and web navigation URLs reject executable/local schemes and embedded credentials', () => {
  const attacks = [
    'javascript:alert(1)',
    'data:text/html,<h1>Hello</h1>',
    'file:///C:/Windows/win.ini',
    'chrome://settings',
    'https://user:pass@example.com/',
    'https://user@example.com/',
    'mailto:user@example.com',
    'shell:AppsFolder',
  ];
  for (const address of attacks) {
    assert.equal(webURL(address), null, address);
    assert.throws(() => normalizeAddress(address), undefined, address);
  }
  assert.equal(webURL({ toString: () => 'https://example.com/' }), null);
  assert.equal(webURL('https://example.com/' + 'a'.repeat(33000)), null);
});

test('typed local development addresses remain usable without opening non-web schemes', () => {
  assert.equal(normalizeAddress('localhost:8080/test'), 'http://localhost:8080/test');
  assert.equal(normalizeAddress('[::1]:8080/test'), 'http://[::1]:8080/test');
  assert.equal(normalizeAddress('example.com'), 'https://example.com/');
  assert.equal(
    normalizeAddress('search terms & credential=none'),
    'https://duckduckgo.com/?q=search%20terms%20%26%20credential%3Dnone',
  );
  assert.throws(() => normalizeAddress('https://example.com/\u0000evil'), /invalid characters/);
});

test('download filenames cannot traverse paths, use alternate data streams, or use Windows device names', () => {
  for (const name of [
    '../escape.pdf',
    'C:\\escape.pdf',
    'report:payload.exe',
    'file\u0000.txt',
    '.hidden',
    'report.',
    'CON',
    'con.txt',
    'COM1.pdf',
    'LPT¹.txt',
    'NUL.pdf',
    'AUX',
  ]) {
    assert.throws(() => safeFilename(name), undefined, name);
  }
  assert.equal(safeFilename('Annual report', 'original.PDF'), 'Annual report.PDF');
  assert.throws(() => safeFilename('invoice.exe', 'original.pdf'), /original/);
});

test('download names reject Unicode direction controls that disguise dangerous extensions', () => {
  for (const name of ['invoice\u202Efdp.exe', 'invoice\u2066pdf.exe', 'report\u007f.pdf']) {
    assert.throws(() => safeFilename(name), undefined, JSON.stringify(name));
  }
});

test('filename collision selection preserves existing downloads and uses numbered names', async (t) => {
  const directory = await tempDirectory(t);
  await fs.writeFile(path.join(directory, 'report.pdf'), 'first');
  await fs.writeFile(path.join(directory, 'report (1).pdf'), 'second');
  assert.equal(await unusedPath(directory, 'report.pdf'), path.join(directory, 'report (2).pdf'));
  assert.equal(await fs.readFile(path.join(directory, 'report.pdf'), 'utf8'), 'first');
});

test('renaming a download never overwrites an existing destination', async (t) => {
  const directory = await tempDirectory(t);
  const from = path.join(directory, 'original.pdf');
  const to = path.join(directory, 'existing.pdf');
  await fs.writeFile(from, 'original');
  await fs.writeFile(to, 'existing');
  await assert.rejects(renameWithoutOverwrite(from, to), { code: 'EEXIST' });
  assert.equal(await fs.readFile(from, 'utf8'), 'original');
  assert.equal(await fs.readFile(to, 'utf8'), 'existing');
});

test('concurrent renames racing for one name keep the losing source intact', async (t) => {
  const directory = await tempDirectory(t);
  const first = path.join(directory, 'first.pdf');
  const second = path.join(directory, 'second.pdf');
  const target = path.join(directory, 'target.pdf');
  await fs.writeFile(first, 'first');
  await fs.writeFile(second, 'second');
  const results = await Promise.allSettled([
    renameWithoutOverwrite(first, target),
    renameWithoutOverwrite(second, target),
  ]);
  assert.equal(results.filter((item) => item.status === 'fulfilled').length, 1);
  const winner = results[0].status === 'fulfilled' ? 'first' : 'second';
  const loser = winner === 'first' ? second : first;
  assert.equal(await fs.readFile(target, 'utf8'), winner);
  assert.equal(await fs.readFile(loser, 'utf8'), winner === 'first' ? 'second' : 'first');
});

test('portable imports cannot introduce privileged extension paths, permissions, or downloads', () => {
  const store = new BrowserStore();
  const raw = {
    ...createInitialState(),
    format: 'zacro-export',
    downloads: [{ id: 'evil-download', profileId: 'default', path: 'C:\\sensitive.txt', state: 'completed' }],
    extensions: [{ id: 'evil-extension', profileId: 'default', path: 'C:\\extension', enabled: true }],
    permissions: [
      { profileId: 'default', origin: 'https://evil.example', permission: 'media', allowed: true },
    ],
  };
  store.importData(raw);
  assert.equal(store.state.downloads.length, 0);
  assert.equal(store.state.extensions.length, 0);
  assert.equal(store.state.permissions.length, 0);
});

test('hydration derives tab profile from its Space and discards unsafe URLs', () => {
  const raw = createInitialState();
  raw.profiles.push({ id: 'other', name: 'Other', private: false });
  raw.tabs.push({ id: 'unsafe-tab', spaceId: 'home', profileId: 'other', url: 'file:///C:/secret.txt' });
  const restored = hydrate(raw);
  assert.equal(restored.tabs[0].profileId, 'default');
  assert.equal(restored.tabs[0].url, 'zacro://newtab');
});

test('private profile artifacts do not appear in saved state, exports, or history', async (t) => {
  const directory = await tempDirectory(t);
  const store = new BrowserStore(directory);
  const profile = store.dispatch('profile:create', { name: 'PrivateSecret', private: true });
  const tab = store.dispatch('tab:create', { url: 'https://private.example/secret' });
  store.dispatch('history:add', { profileId: profile.id, url: tab.url, title: 'Secret page' });
  store.state.downloads.push({ id: 'private-download', profileId: profile.id, name: 'SecretFile.pdf' });
  store.dispatch('bookmark:toggle', { url: tab.url, title: 'Secret bookmark' });
  store.flush();
  const persisted = await fs.readFile(path.join(directory, 'browser-state.json'), 'utf8');
  assert.ok(!persisted.includes('private.example'));
  assert.ok(!persisted.includes('PrivateSecret'));
  assert.ok(!persisted.includes('SecretFile'));
  assert.ok(!JSON.stringify(store.exportData()).includes('private.example'));
  assert.equal(store.state.history.length, 0);
});

test('settings import is allowlisted and cannot inject network endpoints or prototype properties', () => {
  const payload = JSON.parse(
    '{"__proto__":{"polluted":true},"aiBaseUrl":"https://evil.example","theme":"dark","openSourcesLimit":999999,"sidebarWidth":1}',
  );
  const settings = validateSettings(payload);
  assert.equal(settings.theme, 'dark');
  assert.equal(settings.openSourcesLimit, 10);
  assert.equal(settings.sidebarWidth, 200);
  assert.equal(settings.aiBaseUrl, undefined);
  assert.equal({}.polluted, undefined);
});

test('bookmark migration drops scripted and credential-bearing URLs without executing markup', () => {
  const bookmarks = parseBookmarksHtml(
    '<DL><DT><A HREF="javascript:alert(1)">Bad</A><DT><A HREF="https://user:pass@example.com">Credential</A><DT><A HREF="https://example.com/?q=a&amp;b=2"><img src=x onerror=alert(1)>Good &amp; safe</A></DL>',
  );
  assert.deepEqual(bookmarks, [{ url: 'https://example.com/?q=a&b=2', title: 'Good & safe' }]);
});
