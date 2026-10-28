'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const modulePromise = import(pathToFileURL(path.join(root, 'extension/workspace.mjs')));

function browserProfile() {
  const tabs = new Map([
    [
      1,
      {
        id: 1,
        windowId: 7,
        index: 0,
        incognito: false,
        pinned: true,
        active: true,
        groupId: -1,
        title: 'Pinned',
        url: 'https://pinned.example/',
      },
    ],
    [
      2,
      {
        id: 2,
        windowId: 7,
        index: 1,
        incognito: false,
        pinned: false,
        active: false,
        groupId: 11,
        title: 'Notes',
        url: 'https://notes.example/document?oauth_code=private#secret',
      },
    ],
    [
      3,
      {
        id: 3,
        windowId: 7,
        index: 2,
        incognito: false,
        pinned: false,
        active: false,
        groupId: -1,
        title: 'Reading',
        url: 'https://reading.example/',
      },
    ],
    [
      4,
      {
        id: 4,
        windowId: 8,
        index: 0,
        incognito: false,
        pinned: false,
        active: false,
        groupId: 12,
        title: 'Other window',
        url: 'https://other.example/',
      },
    ],
    [
      5,
      {
        id: 5,
        windowId: 7,
        index: 3,
        incognito: true,
        pinned: false,
        active: false,
        groupId: -1,
        title: 'Private',
        url: 'https://private.example/',
      },
    ],
  ]);
  const groups = new Map([
    [11, { id: 11, windowId: 7, title: 'Work', color: 'purple', collapsed: false }],
    [12, { id: 12, windowId: 8, title: 'Elsewhere', color: 'blue', collapsed: false }],
  ]);
  const stored = {};
  const operations = [];
  let nextTab = 10;
  let nextGroup = 20;
  const api = {
    tabs: {
      // Deliberately return too much: the component must still reject private
      // and foreign-window records rather than rely on a permissive test double.
      query: async () => [...tabs.values()].map((tab) => ({ ...tab })),
      get: async (id) => {
        if (!tabs.has(id)) throw new Error('Tab unavailable');
        return { ...tabs.get(id) };
      },
      create: async (options) => {
        operations.push(['create', structuredClone(options)]);
        const tab = {
          id: nextTab++,
          index: tabs.size,
          incognito: false,
          pinned: false,
          groupId: -1,
          title: '',
          ...options,
        };
        tabs.set(tab.id, tab);
        return { ...tab };
      },
      update: async (id, patch) => {
        operations.push(['update', id, structuredClone(patch)]);
        const tab = tabs.get(id);
        if (patch.active)
          for (const other of tabs.values()) if (other.windowId === tab.windowId) other.active = false;
        Object.assign(tab, patch);
        if (patch.pinned) tab.groupId = -1;
        return { ...tab };
      },
      group: async (options) => {
        operations.push(['group', structuredClone(options)]);
        const id = options.groupId ?? nextGroup++;
        if (!groups.has(id))
          groups.set(id, {
            id,
            windowId: options.createProperties.windowId,
            title: '',
            color: 'grey',
            collapsed: false,
          });
        for (const idOfTab of options.tabIds) tabs.get(idOfTab).groupId = id;
        return id;
      },
      ungroup: async (ids) => {
        operations.push(['ungroup', [...ids]]);
        for (const id of ids) tabs.get(id).groupId = -1;
      },
    },
    tabGroups: {
      query: async () => [...groups.values()].map((group) => ({ ...group })),
      get: async (id) => {
        if (!groups.has(id)) throw new Error('Group unavailable');
        return { ...groups.get(id) };
      },
      update: async (id, patch) => {
        operations.push(['group-update', id, structuredClone(patch)]);
        Object.assign(groups.get(id), patch);
        return { ...groups.get(id) };
      },
    },
    storage: {
      local: {
        get: async (key) => ({ [key]: structuredClone(stored[key]) }),
        set: async (value) => {
          Object.assign(stored, structuredClone(value));
        },
      },
    },
  };
  return { api, tabs, groups, stored, operations };
}

test('workspace is a local MV3 side panel with a stable development ID and no page/auth/network capabilities', async () => {
  const manifest = JSON.parse(await fs.readFile(path.join(root, 'extension/manifest.json'), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.incognito, 'not_allowed');
  assert.deepEqual(manifest.permissions.slice().sort(), ['sidePanel', 'storage', 'tabGroups', 'tabs']);
  for (const forbidden of [
    'content_scripts',
    'host_permissions',
    'optional_host_permissions',
    'externally_connectable',
    'web_accessible_resources',
    'chrome_url_overrides',
  ])
    assert.equal(manifest[forbidden], undefined, forbidden);
  assert.match(manifest.content_security_policy.extension_pages, /connect-src 'none'/u);
  assert.match(manifest.content_security_policy.extension_pages, /script-src 'self'/u);
  assert.match(manifest.content_security_policy.extension_pages, /object-src 'none'/u);
  assert.doesNotMatch(manifest.content_security_policy.extension_pages, /unsafe-|https?:/u);
  const id = [
    ...crypto.createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest().subarray(0, 16),
  ]
    .map((byte) => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15)))
    .join('');
  assert.equal(id, 'fimeokmnmdjlnadhinihgiaimdfinehg');
  for (const file of ['panel.js', 'workspace.mjs', 'background.js']) {
    const source = await fs.readFile(path.join(root, 'extension', file), 'utf8');
    assert.doesNotMatch(
      source,
      /\b(?:fetch|XMLHttpRequest|WebSocket|EventSource|eval)\s*\(|\.\s*(?:executeScript|captureVisibleTab|sendMessage|connectNative)\s*\(/u,
      file,
    );
    assert.doesNotMatch(source, /\bconsole\s*\.|innerHTML|document\.write/u, file);
  }
});

test('new pages accept only explicit HTTP(S) addresses and never inherit caller-supplied window identity', async () => {
  const { createWorkspace, webAddress } = await modulePromise;
  const fixture = browserProfile();
  const workspace = createWorkspace(fixture.api, 7);
  for (const input of [
    'javascript:alert(1)',
    'data:text/html,test',
    'file:///private',
    'chrome://settings',
    'about:blank',
    '//example.com',
    'https://user:secret@example.com/',
    'https://example.com/\nsecret',
    '',
    null,
  ]) {
    assert.throws(() => webAddress(input));
    await assert.rejects(workspace.dispatch('create', { url: input }));
  }
  assert.deepEqual(fixture.operations, []);
  await workspace.dispatch('create', { url: ' https://example.com/a?b=c#d ', windowId: 8, incognito: true });
  await workspace.dispatch('create', { url: 'http://127.0.0.1:8080/fixture' });
  assert.deepEqual(
    fixture.operations.map((entry) => entry[1]),
    [
      { windowId: 7, url: 'https://example.com/a?b=c#d', active: true },
      { windowId: 7, url: 'http://127.0.0.1:8080/fixture', active: true },
    ],
  );
});

test('private and other-window tabs never enter the workspace or receive its actions', async () => {
  const { createWorkspace } = await modulePromise;
  const fixture = browserProfile();
  const workspace = createWorkspace(fixture.api, 7);
  const snapshot = await workspace.read();
  assert.deepEqual(
    snapshot.tabs.map((tab) => tab.id),
    [1, 2, 3],
  );
  assert.deepEqual(
    snapshot.groups.map((group) => group.id),
    [11],
  );
  for (const tabId of [4, 5, -1, '2']) {
    await assert.rejects(workspace.dispatch('activate', { tabId }));
    await assert.rejects(workspace.dispatch('pin', { tabId }));
    await assert.rejects(workspace.dispatch('move', { tabId, groupId: 11 }));
  }
  await assert.rejects(workspace.dispatch('move', { tabId: 2, groupId: 12 }));
  await assert.rejects(
    workspace.dispatch('edit-group', { groupId: 12, title: 'Wrong window', color: 'blue' }),
  );
  await assert.rejects(workspace.dispatch('execute-script', { tabId: 2 }));
  assert.deepEqual(fixture.operations, []);
});

test('native tab identity survives activation, pinning and workspace moves without copying or reopening pages', async () => {
  const { createWorkspace, project, tabHost } = await modulePromise;
  const fixture = browserProfile();
  const workspace = createWorkspace(fixture.api, 7);
  await workspace.dispatch('activate', { tabId: 2 });
  assert.equal(fixture.tabs.get(2).active, true);
  assert.equal(fixture.tabs.get(1).active, false);
  const originalURL = fixture.tabs.get(2).url;
  await workspace.dispatch('pin', { tabId: 2 });
  assert.equal(fixture.tabs.get(2).pinned, true);
  await assert.rejects(workspace.dispatch('move', { tabId: 2, groupId: 11 }));
  await workspace.dispatch('pin', { tabId: 2 });
  await workspace.dispatch('move', { tabId: 2, groupId: 11 });
  assert.equal(fixture.tabs.get(2).groupId, 11);
  assert.equal(fixture.tabs.get(2).url, originalURL);
  assert.equal(
    fixture.operations.some(([type]) => type === 'create'),
    false,
  );
  const filtered = project(await workspace.read(), { filter: 11, query: '' });
  assert.deepEqual(
    filtered.pins.map((tab) => tab.id),
    [1],
  );
  assert.deepEqual(
    filtered.sections.flatMap((group) => group.tabs.map((tab) => tab.id)),
    [2],
  );
  assert.equal(tabHost(fixture.tabs.get(2)), 'notes.example');
  assert.equal(
    project(await workspace.read(), { query: 'oauth_code=private' }).count,
    0,
    'Query and fragment tokens are not searchable or displayed',
  );
  assert.equal(project(await workspace.read(), { query: 'notes' }).count, 1);
});

test('workspace creation and editing use native group IDs and invalid fields have no side effects', async () => {
  const { createWorkspace, project } = await modulePromise;
  const fixture = browserProfile();
  const workspace = createWorkspace(fixture.api, 7);
  for (const payload of [
    { tabId: 2, title: '', color: 'blue' },
    { tabId: 2, title: 'x'.repeat(49), color: 'blue' },
    { tabId: 2, title: 'Work', color: 'url(https://other.example)' },
    { tabId: 1, title: 'Work', color: 'blue' },
  ])
    await assert.rejects(workspace.dispatch('create-group', payload));
  assert.deepEqual(fixture.operations, []);
  const created = await workspace.dispatch('create-group', { tabId: 3, title: ' Reading ', color: 'green' });
  assert.equal(fixture.tabs.get(3).groupId, created.groupId);
  assert.deepEqual(fixture.groups.get(created.groupId), {
    id: created.groupId,
    windowId: 7,
    title: 'Reading',
    color: 'green',
    collapsed: false,
  });
  await workspace.dispatch('edit-group', { groupId: created.groupId, title: 'Research', color: 'pink' });
  await workspace.dispatch('collapse-group', { groupId: created.groupId });
  assert.equal(fixture.groups.get(created.groupId).title, 'Research');
  assert.equal(fixture.groups.get(created.groupId).collapsed, true);
  await workspace.dispatch('move', { tabId: 3, groupId: -1 });
  assert.equal(fixture.tabs.get(3).groupId, -1);
  fixture.groups.delete(created.groupId);
  assert.equal(
    project(await workspace.read(), { filter: created.groupId }).selected,
    'all',
    'Stale session-only group IDs fall back without restoring unrelated groups',
  );
  assert.deepEqual(fixture.stored, {});
});

test('appearance is the only persisted component data and separate browser profile stores stay separate', async () => {
  const { createWorkspace, PREFERENCE_KEY } = await modulePromise;
  const first = browserProfile();
  const second = browserProfile();
  const a = createWorkspace(first.api, 7);
  const b = createWorkspace(second.api, 7);
  await a.savePreferences({
    appearance: 'dark',
    tabs: [...first.tabs.values()],
    selectedGroupId: 11,
    token: 'must-not-persist',
  });
  assert.deepEqual(first.stored, { [PREFERENCE_KEY]: { appearance: 'dark' } });
  assert.deepEqual(await b.loadPreferences(), { appearance: 'system' });
  await a.dispatch('pin', { tabId: 2 });
  assert.equal(second.tabs.get(2).pinned, false);
  first.stored[PREFERENCE_KEY] = { appearance: 'unsupported', url: 'https://private.example/' };
  assert.deepEqual(await a.loadPreferences(), { appearance: 'system' });
  assert.deepEqual(await a.savePreferences({ appearance: 'unsupported' }), { appearance: 'system' });
});

test('actions recheck current tab ownership instead of trusting a rendered snapshot', async () => {
  const { createWorkspace } = await modulePromise;
  const fixture = browserProfile();
  const workspace = createWorkspace(fixture.api, 7);
  await workspace.read();
  fixture.tabs.get(2).windowId = 8;
  await assert.rejects(workspace.dispatch('activate', { tabId: 2 }));
  await assert.rejects(workspace.dispatch('create-group', { tabId: 2, title: 'Work', color: 'green' }));
  fixture.tabs.delete(3);
  await assert.rejects(workspace.dispatch('pin', { tabId: 3 }));
  assert.deepEqual(fixture.operations, []);
});
