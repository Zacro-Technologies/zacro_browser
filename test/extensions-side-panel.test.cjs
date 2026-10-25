'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { SidePanelController, panelBounds } = require('../src/main/extensions/side-panel.cjs');
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'zacro-panel-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const context = { profileId: 'one', extensionId: 'a'.repeat(32), generation: 'g1' };
  const metadata = {
    enabled: true,
    generation: 'g1',
    manifest: { name: 'Panel', side_panel: { default_path: 'panel.html' } },
    grants: { permissions: ['sidePanel'] },
  };
  let profile = 'one',
    activeTab = 10;
  const attached = new Set(),
    created = [];
  const window = {
    id: 1,
    isDestroyed: () => false,
    getContentSize: () => [1000, 700],
    contentView: { addChildView: (v) => attached.add(v), removeChildView: (v) => attached.delete(v) },
  };
  class View {
    constructor(options) {
      this.options = options;
      this.webContents = new EventEmitter();
      Object.assign(this.webContents, {
        isDestroyed: () => !!this.dead,
        close: () => {
          this.dead = true;
        },
        setWindowOpenHandler: () => {},
        loadURL: async (url) => {
          this.url = url;
        },
      });
      created.push(this);
    }
    setBounds(bounds) {
      this.bounds = bounds;
    }
    setVisible(visible) {
      this.visible = visible;
    }
  }
  const options = {
    native: { WebContentsView: View },
    resolveExtension: (p, id) => (p === 'one' && id === context.extensionId ? metadata : null),
    getProfile: (id) => ({ id, private: id === 'private' }),
    activeProfile: () => ({ id: profile }),
    getSession: () => 'owned-session',
    getWindow: () => window,
    activeTabId: () => activeTab,
    getTab: (p, id) => {
      if (p !== 'one' || ![10, 11].includes(id)) throw Error('Unknown profile tab');
      return { id, windowId: 1 };
    },
    profilePath: () => directory,
    changed: () => {},
  };
  const controller = new SidePanelController(options);
  return {
    controller,
    options,
    context,
    metadata,
    attached,
    created,
    setProfile: (p) => {
      profile = p;
    },
    setTab: (id) => {
      activeTab = id;
    },
  };
}
test('panel defaults, persisted global options and behavior, ephemeral per-tab overrides', async (t) => {
  const f = fixture(t),
    c = f.controller;
  assert.deepEqual(await c.call(f.context, 'getOptions', [{}]), { path: 'panel.html', enabled: true });
  await c.call(f.context, 'setOptions', [{ path: 'other.html' }]);
  await c.call(f.context, 'setOptions', [{ tabId: 10, enabled: false }]);
  assert.deepEqual(await c.call(f.context, 'getOptions', [{ tabId: 10 }]), {
    tabId: 10,
    path: 'other.html',
    enabled: false,
  });
  await c.call(f.context, 'setPanelBehavior', [{ openPanelOnActionClick: true }]);
  const restarted = new SidePanelController(f.options);
  assert.deepEqual(await restarted.call(f.context, 'getOptions', [{ tabId: 10 }]), {
    tabId: 10,
    path: 'other.html',
    enabled: true,
  });
  assert.deepEqual(await restarted.call(f.context, 'getPanelBehavior', []), { openPanelOnActionClick: true });
  for (const value of [
    '../bad.html',
    '/bad.html',
    'https://evil/p',
    'a%2fb.html',
    'zacro-compat-transport.html',
    'zacro-native-services.html',
  ])
    await assert.rejects(c.call(f.context, 'setOptions', [{ path: value }]), /resource/);
});
test('open requires a consumed host gesture and rejects foreign, private and expired ownership', async (t) => {
  const f = fixture(t),
    c = f.controller;
  await assert.rejects(c.call(f.context, 'open', [{ windowId: 1 }]), /gesture/);
  c.recordGesture(f.context);
  await assert.rejects(c.call(f.context, 'open', [{ tabId: 90 }]), /profile tab/);
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  await assert.rejects(c.call(f.context, 'open', [{ windowId: 1 }]), /gesture/);
  f.setProfile('two');
  c.recordGesture(f.context);
  await assert.rejects(c.call(f.context, 'open', [{ windowId: 1 }]), /profile/);
  f.metadata.generation = 'g2';
  await assert.rejects(c.call(f.context, 'getOptions', [{}]), /Expired/);
});
test('attached panel uses bounded right region, hides for overlays and tears down scoped tabs', async (t) => {
  const f = fixture(t),
    c = f.controller;
  await c.call(f.context, 'setOptions', [{ tabId: 10, path: 'tab.html' }]);
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ tabId: 10 }]);
  c.arrange({ sidebarWidth: 224, panelWidth: 336, contentTop: 8, extensionPanel: true, overlay: false });
  const v = f.created[0];
  assert.equal(f.attached.has(v), true);
  assert.deepEqual(v.bounds, { x: 656, y: 56, width: 336, height: 636 });
  assert.deepEqual(v.options.webPreferences, {
    session: 'owned-session',
    sandbox: true,
    contextIsolation: true,
    nodeIntegration: false,
    nodeIntegrationInSubFrames: false,
    webSecurity: true,
  });
  c.arrange({ panelWidth: 336, contentTop: 8, extensionPanel: true, overlay: true });
  assert.equal(f.attached.has(v), false);
  assert.equal(v.dead, undefined);
  f.setTab(11);
  c.reconcile();
  assert.equal(v.dead, true);
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  f.setTab(10);
  c.reconcile();
  assert.ok(c.snapshot());
  f.setProfile('two');
  c.reconcile();
  assert.equal(c.snapshot(), null);
});
test('panel geometry always stays within tiny and malformed shell sizes', () => {
  for (const size of [
    [1000, 700],
    [1, 1],
    [300, 60],
  ]) {
    const b = panelBounds(size, { panelWidth: 1e9, sidebarWidth: 224, contentTop: 1e9 });
    assert.ok(b.x >= 0 && b.y >= 0 && b.width >= 1 && b.height >= 1);
    assert.ok(b.x + b.width <= size[0] && b.y + b.height <= size[1]);
  }
});
test('tab open falls back to the global panel when there is no tab override', async (t) => {
  const f = fixture(t),
    c = f.controller;
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ tabId: 10 }]);
  assert.equal(c.snapshot().tabId, undefined);
  f.setTab(11);
  c.reconcile();
  assert.ok(c.snapshot());
  await assert.rejects(c.call(f.context, 'close', [{ tabId: 11 }]), /global/);
});
test('a new packaged path enables a panel without a manifest default', async (t) => {
  const f = fixture(t);
  f.metadata.manifest.side_panel = undefined;
  await f.controller.call(f.context, 'setOptions', [{ path: 'dynamic.html' }]);
  assert.equal((await f.controller.call(f.context, 'getOptions', [{}])).enabled, true);
});
test('an opened panel outlives its calling document while retaining extension generation ownership', async (t) => {
  const f = fixture(t),
    c = f.controller;
  let alive = true;
  const origin = {
    ...f.context,
    assertCurrent: () => {
      if (!alive) throw Error('Document closed');
    },
  };
  c.recordGesture(origin);
  await c.call(origin, 'open', [{ windowId: 1 }]);
  alive = false;
  c.reconcile();
  assert.ok(c.snapshot());
  f.metadata.enabled = false;
  c.reconcile();
  assert.equal(c.snapshot(), null);
});
test('changing the configured path replaces an open panel and destroys old access without another gesture', async (t) => {
  const f = fixture(t),
    c = f.controller;
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  await c.call(f.context, 'setOptions', [{ path: 'replacement.html' }]);
  assert.equal(f.created[0].dead, true);
  assert.ok(c.snapshot());
  assert.equal(f.created[1].url, `chrome-extension://${f.context.extensionId}/replacement.html`);
});
test('window close leaves tab-scoped panels alone and disabling the current tab hides a global panel', async (t) => {
  const f = fixture(t),
    c = f.controller;
  await c.call(f.context, 'setOptions', [{ tabId: 10, path: 'tab.html' }]);
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ tabId: 10 }]);
  await c.call(f.context, 'close', [{ windowId: 1 }]);
  assert.equal(c.snapshot()?.tabId, 10);
  await c.call(f.context, 'close', [{ tabId: 10 }]);
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  await c.call(f.context, 'setOptions', [{ tabId: 10, enabled: false }]);
  assert.equal(c.snapshot(), null);
});
test('profile removal immediately destroys its panel before profile teardown awaits', async (t) => {
  const f = fixture(t),
    c = f.controller;
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  c.revokeProfile('one');
  assert.equal(c.snapshot(), null);
  assert.equal(f.created[0].dead, true);
  assert.equal(c.states.size, 0);
  assert.equal(c.gestures.size, 0);
});
test('self replacement retains the new generation-owned panel after its original document is destroyed', async (t) => {
  const f = fixture(t),
    c = f.controller;
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  const old = f.created[0];
  const origin = {
    ...f.context,
    sourceContents: old.webContents,
    assertCurrent: () => {
      if (old.dead) throw Error('Expired extension context');
    },
  };
  await c.call(origin, 'setOptions', [{ path: 'replacement.html' }]);
  assert.equal(old.dead, true);
  assert.equal(f.created[1].dead, undefined);
  assert.ok(c.snapshot());
  await assert.rejects(c.call(origin, 'setOptions', [{ path: 'forged.html' }]), /Expired/);
  assert.equal((await c.call(f.context, 'getOptions', [{}])).path, 'replacement.html');
});
test('normal extension-tab input is document-bound and is rebound only after another genuine event', async (t) => {
  const f = fixture(t),
    c = f.controller;
  const contents = {
    id: 10,
    session: 'owned-session',
    isDestroyed: () => false,
    getURL: () => `chrome-extension://${f.context.extensionId}/tab.html`,
  };
  const entry = { contents, profileId: 'one', documentEpoch: 1, disposing: false };
  c.recordTabInput(entry, { type: 'mouseDown' });
  entry.documentEpoch++;
  await assert.rejects(c.call(f.context, 'open', [{ windowId: 1 }]), /document/);
  c.recordTabInput(entry, { type: 'mouseDown' });
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  assert.ok(c.snapshot());
  c.destroy();
  contents.getURL = () => 'https://ordinary.example/';
  c.recordTabInput(entry, { type: 'mouseDown' });
  await assert.rejects(c.call(f.context, 'open', [{ windowId: 1 }]), /gesture/);
});
test('self replacement still destroys its new view if the extension generation changes during load', async (t) => {
  const f = fixture(t),
    View = f.options.native.WebContentsView;
  f.options.native.WebContentsView = class extends View {
    constructor(options) {
      super(options);
      const load = this.webContents.loadURL;
      this.webContents.loadURL = async (url) => {
        await load(url);
        if (f.created.length === 2) f.metadata.generation = 'g2';
      };
    }
  };
  const c = f.controller;
  c.recordGesture(f.context);
  await c.call(f.context, 'open', [{ windowId: 1 }]);
  const old = f.created[0],
    origin = {
      ...f.context,
      sourceContents: old.webContents,
      assertCurrent: () => {
        if (old.dead) throw Error('Expired source');
      },
    };
  await assert.rejects(c.call(origin, 'setOptions', [{ path: 'replacement.html' }]), /Expired/);
  assert.equal(c.snapshot(), null);
  assert.equal(f.created[1].dead, true);
});
