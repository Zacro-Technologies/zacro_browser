'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
let ExtensionAPI;
try {
  ({ ExtensionAPI } = require('../src/main/extensions/api.cjs'));
} catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
}
const id = 'a'.repeat(32);
function setup(extra = {}) {
  assert.ok(ExtensionAPI, 'browser API adapter must exist');
  const metadata = {
    enabled: true,
    generation: 'g1',
    manifest: {
      manifest_version: 3,
      action: { default_popup: 'popup.html' },
      options_ui: { page: 'options.html' },
      commands: { hello: { suggested_key: { default: 'Ctrl+Shift+Y' }, description: 'Hello' } },
      optional_permissions: ['tabs'],
    },
    grants: { permissions: ['storage', 'activeTab', 'contextMenus'], origins: [] },
  };
  const data = [
    {
      id: 10,
      windowId: 1,
      active: true,
      index: 0,
      url: 'https://example.com/draft',
      title: 'Draft',
      favIconUrl: 'https://example.com/icon',
    },
  ];
  const effects = [],
    events = [];
  const api = new ExtensionAPI({
    resolveExtension: (profile, extension) => (profile === 'p1' && extension === id ? metadata : null),
    tabs: {
      query: async (profile) => (profile === 'p1' ? structuredClone(data) : []),
      get: async (profile, tab) =>
        profile === 'p1' ? structuredClone(data.find((item) => item.id === tab)) : null,
      update: async (profile, tab, props, guard) => {
        guard();
        Object.assign(
          data.find((item) => item.id === tab),
          props,
        );
        return structuredClone(data[0]);
      },
      create: async (profile, props, guard) => {
        guard();
        const item = { id: 11, windowId: 1, ...props };
        data.push(item);
        return item;
      },
      remove: async (profile, ids, guard) => {
        guard();
        for (const tab of ids)
          data.splice(
            data.findIndex((item) => item.id === tab),
            1,
          );
      },
      reload: async (profile, tab, props, guard) => {
        guard();
        effects.push(['reload', profile, tab]);
      },
    },
    windows: {
      getCurrent: async () => ({ id: 1, type: 'normal' }),
      getAll: async () => [{ id: 1, type: 'normal' }],
    },
    dialogs: {
      openView: async (profile, extension, details, guard) => {
        guard();
        effects.push(details);
      },
      requestPermissions: async () => true,
    },
    menus: { changed: () => {} },
    emit: (...args) => events.push(args),
    ...extra,
  });
  const context = { profileId: 'p1', extensionId: id, metadata, generation: 'g1', kind: 'extension-frame' };
  return { api, context, metadata, data, effects, events };
}
test('tabs redact sensitive fields without grants and activeTab expires on origin change', async () => {
  const { api, context, data } = setup();
  assert.deepEqual(await api.call(context, 'tabs.query', [{}]), [
    { id: 10, windowId: 1, active: true, index: 0 },
  ]);
  await api.activateAction('p1', id, 10);
  assert.equal((await api.call(context, 'tabs.get', [10])).url, 'https://example.com/draft');
  data[0].url = 'https://other.example/';
  assert.equal((await api.call(context, 'tabs.get', [10])).url, undefined);
  await assert.rejects(api.call(context, 'tabs.update', [10, { url: 'javascript:alert(1)' }]), /URL/);
  await assert.rejects(api.call(context, 'tabs.get', [999]), /tab/i);
});
test('content cannot call privileged APIs, unknown APIs and new windows reject', async () => {
  const { api, context } = setup();
  await assert.rejects(
    api.call({ ...context, kind: 'content-script' }, 'tabs.create', [{ url: 'https://example.com/' }]),
    /Trusted/,
  );
  await assert.rejects(api.call(context, 'windows.create', [{}]), /Unsupported/);
  await assert.rejects(api.call(context, 'nativeMessaging.connect', []), /Unsupported/);
  assert.deepEqual(await api.call(context, 'windows.getAll', [{}]), [{ id: 1, type: 'normal' }]);
});
test('actions and options resolve only same-extension resources and lifecycle checks guard delayed effects', async () => {
  const { api, context, effects, metadata } = setup();
  await api.activateAction('p1', id, 10);
  await api.call(context, 'runtime.openOptionsPage', []);
  assert.equal(effects[0].url, `chrome-extension://${id}/popup.html`);
  assert.equal(effects[1].url, `chrome-extension://${id}/options.html`);
  await assert.rejects(
    api.call(context, 'action.setPopup', [{ popup: 'https://evil.example/' }]),
    /resource/,
  );
  metadata.enabled = false;
  await assert.rejects(api.call(context, 'tabs.query', [{}]), /disabled|Expired/i);
});
test('tab events redact and menu and command dispatch are bound to host generation', async () => {
  const { api, context, events, metadata } = setup();
  const menu = await api.call(context, 'contextMenus.create', [
    { id: 'read', title: 'Read', contexts: ['page'] },
  ]);
  assert.equal(menu, 'read');
  await api.clickMenu('p1', id, 'read', { pageUrl: 'https://example.com/draft' }, 10);
  assert.equal(events.at(-1)[2], 'contextMenus.onClicked');
  assert.equal(events.at(-1)[3][0].menuItemId, 'read');
  const commands = await api.call(context, 'commands.getAll', []);
  assert.equal(commands[0].name, 'hello');
  assert.equal(commands[0].shortcut, process.platform === 'darwin' ? 'Command+Shift+Y' : 'Ctrl+Shift+Y');
  await api.dispatchCommand('p1', id, 'hello', 10);
  assert.equal(events.at(-1)[2], 'commands.onCommand');
  metadata.generation = 'g2';
  assert.deepEqual(api.menuItems('p1', id), []);
  await assert.rejects(api.call(context, 'contextMenus.update', ['read', { title: 'stale' }]), /Expired/);
});
test('permission requests require host-issued gesture and cannot grant undeclared rights', async () => {
  const changes = [];
  const { api, context, metadata } = setup({
    changePermissions: async (profile, extension, grants) => {
      changes.push(grants);
      metadata.grants = grants;
      return { enabled: true };
    },
  });
  await assert.rejects(
    api.call(context, 'permissions.request', [{ permissions: ['tabs'], userGesture: true }]),
    /gesture/i,
  );
  await api.activateAction('p1', id, 10);
  assert.equal(await api.call(context, 'permissions.request', [{ permissions: ['tabs'] }]), true);
  assert.equal(changes[0].permissions.includes('tabs'), true);
  assert.equal(await api.call(context, 'permissions.contains', [{ permissions: ['tabs'] }]), true);
  await assert.rejects(
    api.call(context, 'permissions.request', [{ permissions: ['debugger'] }]),
    /declared|Unsupported/,
  );
});
test('storage passes authenticated trust and keeps sync events behind per-context access checks', async () => {
  const observed = [];
  const { api, context } = setup({
    storage: {
      call: async (context, method, args) => {
        observed.push([context.kind, method, args]);
        return { value: 42 };
      },
    },
  });
  assert.deepEqual(await api.call(context, 'storage.sync.get', ['value']), { value: 42 });
  assert.deepEqual(observed, [['extension-frame', 'get', ['value']]]);
  await assert.rejects(api.call(context, 'storage.local.get', []), /native|Unsupported/i);
});
test('manager optional grant rebuild persists only approved native rights and retains reload barrier', async (t) => {
  const fs = require('node:fs/promises'),
    os = require('node:os'),
    path = require('node:path');
  const { ExtensionManager } = require('../src/main/extensions/manager.cjs');
  const { idFromKey } = require('../src/main/extensions/packages.cjs');
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-api-grants-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const source = path.join(root, 'source');
  await fs.mkdir(source);
  const original = {
    manifest_version: 3,
    name: 'Grants',
    version: '1',
    permissions: ['storage'],
    optional_permissions: ['tabs', 'scripting'],
    optional_host_permissions: ['https://example.com/*'],
  };
  await fs.writeFile(path.join(source, 'manifest.json'), JSON.stringify(original));
  let requireReload = false;
  const loaded = [];
  const ses = {
    extensions: {
      loadExtension: async (directory) => {
        const manifest = JSON.parse(await fs.readFile(path.join(directory, 'manifest.json'), 'utf8'));
        loaded.push(manifest);
        return { id: idFromKey(Buffer.from(manifest.key, 'base64')) };
      },
      removeExtension: () => {},
    },
  };
  const manager = new ExtensionManager({
    root: path.join(root, 'managed'),
    getProfile: (id) => ({ id }),
    getSession: () => ses,
    confirmPermissions: async () => true,
    onDeactivated: async () => ({ requiresPageReload: requireReload }),
  });
  t.after(() => manager.close());
  await manager.restore('p1');
  const record = await manager.installLocal('p1', source);
  assert.equal(typeof manager.changePermissions, 'function', 'native grant rebuild required');
  const next = await manager.changePermissions('p1', record.id, {
    permissions: ['storage', 'scripting'],
    origins: ['https://example.com/*'],
  });
  assert.deepEqual(loaded.at(-1).permissions, ['scripting', 'storage']);
  assert.deepEqual(loaded.at(-1).host_permissions, ['https://example.com/*']);
  assert.deepEqual(loaded.at(-1).optional_permissions, []);
  assert.notEqual(next.current.token, record.current.token);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(source, 'manifest.json'), 'utf8')), original);
  requireReload = true;
  const reduced = await manager.changePermissions('p1', record.id, { permissions: ['storage'], origins: [] });
  assert.equal(reduced.enabled, false);
  assert.equal(reduced.status, 'pending-reload');
  assert.equal(manager.resolveExtension('p1', record.id), null);
  await assert.rejects(manager.enable('p1', record.id), /reload/i);
  requireReload = false;
  await manager.enable('p1', record.id);
  assert.deepEqual(loaded.at(-1).permissions, ['storage']);
  assert.deepEqual(loaded.at(-1).host_permissions, []);
});
test('action setters validate target and preserve global state with per-tab overrides', async () => {
  const { api, context } = setup();
  await api.call(context, 'action.setTitle', [{ title: 'Global' }]);
  await api.call(context, 'action.setBadgeText', [{ text: '2', tabId: 10 }]);
  await api.call(context, 'action.disable', [10]);
  assert.equal(api.actionState('p1', id, 10).enabled, false);
  assert.equal(api.actionState('p1', id, 10).title, 'Global');
  assert.equal(api.actionState('p1', id, 10).badgeText, '2');
  assert.equal(api.actionState('p1', id).badgeText, '');
  await assert.rejects(
    api.call(context, 'action.setBadgeBackgroundColor', [{ color: { unsafe: true } }]),
    /color/i,
  );
});
test('activeTab expires on same-URL navigation event and stale host guards stop delayed mutation', async () => {
  const { api, context, metadata, data } = setup();
  await api.activateAction('p1', id, 10);
  api.publish('p1', 'tabs.onUpdated', [10, { status: 'loading' }, data[0]]);
  assert.equal((await api.call(context, 'tabs.get', [10])).url, undefined);
  api.tabs.update = async (profile, id, props, guard) => {
    await Promise.resolve();
    metadata.generation = 'g2';
    guard();
    Object.assign(data[0], props);
  };
  await assert.rejects(api.call(context, 'tabs.update', [10, { url: 'https://example.com/new' }]), /Expired/);
  assert.equal(data[0].url, 'https://example.com/draft');
});
test('commands detect browser and cross-extension collisions independent of registration order', async () => {
  const { api, metadata } = setup();
  const second = 'b'.repeat(32);
  api.listExtensions = () => [{ id }, { id: second }];
  const resolve = api.resolveExtension;
  api.resolveExtension = (p, key) =>
    key === second
      ? { ...metadata, manifest: { commands: { other: { suggested_key: { default: 'Ctrl+Shift+Y' } } } } }
      : resolve(p, key);
  assert.equal(api.commandsState('p1', id)[0].status, 'conflict');
  metadata.manifest.commands.hello.suggested_key.default = 'Ctrl+T';
  assert.equal(api.commandsState('p1', id)[0].shortcut, '');
});
test('reduced optional grants cannot remove required rights or authorize undeclared hosts', async () => {
  const { api, context, metadata } = setup();
  metadata.manifest.permissions = ['storage'];
  await assert.rejects(api.call(context, 'permissions.remove', [{ permissions: ['storage'] }]), /Required/);
  await api.activateAction('p1', id, 10);
  await assert.rejects(
    api.call(context, 'permissions.request', [{ origins: ['https://evil.example/*'] }]),
    /declared/,
  );
});
test('setIcon rejects unsupported imageData rather than silently discarding icon', async () => {
  const { api, context } = setup();
  await assert.rejects(
    api.call(context, 'action.setIcon', [{ imageData: { width: 1, height: 1, data: [0, 0, 0, 255] } }]),
    /imageData|Unsupported/,
  );
});
test('browser callbacks retain tab CRUD IDs and sanitize event details per receiver', async () => {
  const { api, context, data, events } = setup();
  assert.equal((await api.call(context, 'tabs.create', [{ url: 'https://example.com/new' }])).id, 11);
  await api.call(context, 'tabs.update', [11, { url: 'https://example.com/edited' }]);
  await api.call(context, 'tabs.reload', [11, { bypassCache: true }]);
  api.publish('p1', 'tabs.onUpdated', [10, { url: data[0].url, title: 'private' }, data[0]]);
  assert.deepEqual(events.at(-1)[3][1], {});
  assert.equal(events.at(-1)[3][2].title, undefined);
  await api.call(context, 'tabs.remove', [[11]]);
  assert.equal(data.length, 1);
});
test('explicit host ports match only the granted port', () => {
  const { matches } = require('../src/main/extensions/permissions.cjs');
  assert.equal(matches('http://127.0.0.1:8123/*', 'http://127.0.0.1:8123/a'), true);
  assert.equal(matches('http://127.0.0.1:8123/*', 'http://127.0.0.1:8124/a'), false);
  assert.equal(matches('https://*.example.com:8443/*', 'https://a.example.com:8443/a'), true);
});
test('unsupported native activeTab and MV2 scripting are visible before activation', () => {
  const { inspectManifest } = require('../src/main/extensions/catalog.cjs');
  const required = inspectManifest({
    manifest_version: 3,
    name: 'Temporary access',
    version: '1',
    permissions: ['activeTab'],
  });
  assert.equal(required.compatible, false);
  assert.match(required.unsupported[0].reason, /temporary|one.tab/i);
  const optional = inspectManifest({
    manifest_version: 3,
    name: 'Optional access',
    version: '1',
    optional_permissions: ['activeTab'],
  });
  assert.equal(optional.compatible, true);
  assert.equal(optional.unsupported[0].required, false);
  const legacy = inspectManifest({
    manifest_version: 2,
    name: 'Legacy',
    version: '1',
    permissions: ['scripting'],
  });
  assert.equal(legacy.compatible, false);
});
test('action updates notify the host renderer with current profile and generation guard', async () => {
  let notified;
  const { api, context } = setup({
    onActionChanged: (profile, id, tabId, state, guard) => {
      guard();
      notified = { profile, tabId, state };
    },
  });
  await api.call(context, 'action.setBadgeText', [{ text: '8' }]);
  assert.equal(notified?.profile, 'p1');
  assert.equal(notified.state.badgeText, '8');
});
test('all browser and OS reserved commands remain visibly unassigned', () => {
  const { api, metadata } = setup();
  for (const shortcut of [
    'Ctrl+F',
    'Command+D',
    'Ctrl+K',
    'Command+H',
    'Ctrl+J',
    'Command+B',
    'Command+Comma',
    'Ctrl+P',
    'Ctrl+Enter',
    'Ctrl+Plus',
    'Ctrl+Minus',
    'Ctrl+0',
    'Ctrl+9',
    'Command+Tab',
    'F5',
    'F6',
    'F11',
    'F12',
    'Ctrl+Shift+I',
    'Command+M',
    'Alt+Tab',
    'Command+Space',
  ]) {
    metadata.manifest.commands.hello.suggested_key = { default: shortcut };
    assert.equal(api.commandsState('p1', id)[0].status, 'conflict', shortcut);
  }
});
test('command shortcuts normalize modifier order and reject bare typing keys', () => {
  const { api, metadata } = setup();
  metadata.manifest.commands.hello.suggested_key = { default: 'Shift+Alt+Y' };
  assert.equal(api.commandsState('p1', id)[0].shortcut, 'Alt+Shift+Y');
  metadata.manifest.commands.hello.suggested_key = { default: 'Y' };
  assert.equal(api.commandsState('p1', id)[0].shortcut, '');
});
test('late host effects reject when authenticated originating document has expired', async () => {
  const { api, context, data } = setup();
  let alive = true;
  context.assertCurrent = () => {
    if (!alive) throw new Error('Originating document expired');
  };
  api.tabs.update = async (profile, id, props, guard) => {
    await Promise.resolve();
    alive = false;
    guard();
    Object.assign(data[0], props);
  };
  await assert.rejects(
    api.call(context, 'tabs.update', [10, { url: 'https://example.com/stale' }]),
    /document expired/,
  );
  assert.equal(data[0].url, 'https://example.com/draft');
});
test('tab overloads use the actual active tab and single move returns a tab object', async () => {
  const { api, context, data, effects } = setup();
  data[0].active = false;
  data.push({ id: 11, windowId: 1, active: true, index: 1, url: 'https://example.com/active' });
  await api.call(context, 'tabs.reload', [{ bypassCache: true }]);
  assert.deepEqual(effects.at(-1), ['reload', 'p1', 11]);
  await api.call(context, 'tabs.update', [{ url: 'https://example.com/changed' }]);
  assert.equal(data[1].url, 'https://example.com/changed');
  api.tabs.move = async (_profile, ids) =>
    ids.map((id) => structuredClone(data.find((tab) => tab.id === id)));
  assert.equal((await api.call(context, 'tabs.move', [11, { index: 0 }])).id, 11);
  assert.equal((await api.call(context, 'tabs.move', [[11], { index: 0 }])).length, 1);
});
test('permission changes publish exact deltas after native rebuild completes', async () => {
  let metadata;
  const fixture = setup({
    changePermissions: async (_profile, _id, grants) => {
      metadata.grants = grants;
      return { enabled: true, grants };
    },
  });
  metadata = fixture.metadata;
  await fixture.api.activateAction('p1', id, 10);
  assert.equal(
    await fixture.api.call(fixture.context, 'permissions.request', [{ permissions: ['tabs'] }]),
    true,
  );
  assert.deepEqual(fixture.events.at(-1).slice(2), [
    'permissions.onAdded',
    [{ permissions: ['tabs'], origins: [] }],
  ]);
  assert.equal(
    await fixture.api.call(fixture.context, 'permissions.remove', [{ permissions: ['tabs'] }]),
    true,
  );
  assert.deepEqual(fixture.events.at(-1).slice(2), [
    'permissions.onRemoved',
    [{ permissions: ['tabs'], origins: [] }],
  ]);
});
test('unknown method suffixes cannot alias a supported API method', async () => {
  const { api, context } = setup();
  await assert.rejects(api.call(context, 'tabs.get.extra', [10]), /Unsupported/);
});

test('R2 packaged relative URLs resolve for create/update while foreign and unsafe URLs reject', async () => {
  const { api, context, data } = setup();
  for (const value of ['onboarding.html', '/options.html', 'nested/start.html']) {
    const tab = await api.call(context, 'tabs.create', [{ url: value }]);
    assert.equal(data.at(-1).url, `chrome-extension://${id}/${value.replace(/^\//, '')}`);
    await api.call(context, 'tabs.update', [tab.id, { url: value }]);
  }
  for (const value of [
    `chrome-extension://${'b'.repeat(32)}/x`,
    'zacro-compat-transport.html',
    'javascript:alert(1)',
    'data:text/html,x',
    'https://user:password@example.com/',
    `chrome-extension://user:password@${id}/options.html`,
  ])
    await assert.rejects(api.call(context, 'tabs.create', [{ url: value }]), /URL|resource/);
});
test('R3 optional wildcard declarations grant only requested narrower hosts and contains honors coverage', async () => {
  const { optionalGrants, hostContains } = require('../src/main/extensions/permissions.cjs');
  const manifest = {
    manifest_version: 3,
    name: 'Sites',
    version: '1',
    optional_host_permissions: ['https://*/*'],
  };
  assert.deepEqual(
    optionalGrants(
      manifest,
      { permissions: [], origins: [] },
      { permissions: [], origins: ['https://example.com/*'] },
    ),
    { permissions: [], origins: ['https://example.com/*'] },
  );
  assert.equal(hostContains('https://*.example.com/path/*', 'https://sub.example.com/path/child/*'), true);
  for (const [outer, inner] of [
    ['https://example.com/*', 'https://*/*'],
    ['https://*.example.com/*', 'https://other.com/*'],
    ['https://*/*', 'http://example.com/*'],
    ['https://example.com/path/*', 'https://example.com/other/*'],
    ['http://localhost:123/*', 'http://localhost:456/*'],
  ])
    assert.equal(hostContains(outer, inner), false, `${outer} vs ${inner}`);
  const { api, context, metadata } = setup();
  metadata.grants.origins = ['https://*.example.com/*'];
  assert.equal(
    await api.call(context, 'permissions.contains', [{ origins: ['https://sub.example.com/*'] }]),
    true,
  );
  assert.equal(await api.call(context, 'permissions.contains', [{ origins: ['https://*/*'] }]), false);
  assert.throws(
    () =>
      optionalGrants(
        { ...manifest, host_permissions: ['https://example.com/*'] },
        { permissions: [], origins: ['https://example.com/*'] },
        { permissions: [], origins: ['https://*/*'] },
        true,
      ),
    /Required/,
  );
});
test('R4 checkbox clicks toggle canonical state and ignore caller checked claims', async () => {
  const { api, context, events } = setup();
  await api.call(context, 'contextMenus.create', [
    { id: 'c', type: 'checkbox', title: 'Check', checked: false },
  ]);
  await api.clickMenu('p1', id, 'c', { wasChecked: true, checked: false }, 10);
  assert.equal(api.menuItems('p1', id)[0].checked, true);
  assert.deepEqual(events.at(-1)[3][0], { menuItemId: 'c', wasChecked: false, checked: true });
  await api.clickMenu('p1', id, 'c', {}, 10);
  assert.equal(api.menuItems('p1', id)[0].checked, false);
  assert.deepEqual(events.at(-1)[3][0], { menuItemId: 'c', wasChecked: true, checked: false });
});
test('R4 radios remain exclusive only within contiguous sibling groups and reject stale clicks', async () => {
  const { api, context, metadata } = setup();
  for (const item of [
    { id: 'a', type: 'radio', checked: true },
    { id: 'b', type: 'radio' },
    { id: 'sep', type: 'separator' },
    { id: 'c', type: 'radio', checked: true },
    { id: 'disabled', type: 'checkbox', enabled: false },
  ])
    await api.call(context, 'contextMenus.create', [{ title: 'item', ...item }]);
  await api.clickMenu('p1', id, 'b', {}, 10);
  assert.deepEqual(
    api
      .menuItems('p1', id)
      .filter((item) => item.type === 'radio')
      .map((item) => [item.id, item.checked]),
    [
      ['a', false],
      ['b', true],
      ['c', true],
    ],
  );
  await assert.rejects(api.clickMenu('p1', id, 'disabled', {}, 10), /menu/i);
  api.tabs.get = async () => {
    metadata.generation = 'new';
    return { id: 10, url: 'https://example.com/' };
  };
  await assert.rejects(api.clickMenu('p1', id, 'a', {}, 10), /Expired/);
});
test('R5 submenu removal is atomic across descendants, supports ID reuse, and rejects cycles', async () => {
  const { api, context } = setup();
  for (const item of [{ id: 'p' }, { id: 'c', parentId: 'p' }, { id: 'g', parentId: 'c' }, { id: 'keep' }])
    await api.call(context, 'contextMenus.create', [{ title: 'item', ...item }]);
  await assert.rejects(api.call(context, 'contextMenus.update', ['p', { parentId: 'p' }]), /cycle|parent/i);
  await assert.rejects(api.call(context, 'contextMenus.update', ['p', { parentId: 'g' }]), /cycle|parent/i);
  assert.equal(api.menuItems('p1', id).find((item) => item.id === 'p').parentId, undefined);
  await api.call(context, 'contextMenus.remove', ['p']);
  assert.deepEqual(
    api.menuItems('p1', id).map((item) => item.id),
    ['keep'],
  );
  for (const item of [{ id: 'p' }, { id: 'c', parentId: 'p' }, { id: 'g', parentId: 'c' }])
    await api.call(context, 'contextMenus.create', [{ title: 'new', ...item }]);
  assert.equal(api.menuItems('p1', id).length, 4);
});
