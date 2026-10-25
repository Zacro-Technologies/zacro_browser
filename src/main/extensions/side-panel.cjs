'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { browserLayout, presentView } = require('../layout.cjs');
function resource(value) {
  if (
    typeof value !== 'string' ||
    !value ||
    value.length > 2048 ||
    /[\\\x00-\x20\x7f:%?#]/.test(value) ||
    value.split('/').some((p) => !p || p === '.' || p === '..') ||
    value.startsWith('zacro-')
  )
    throw new Error('Invalid side panel resource');
  return value;
}
function panelBounds(size, layout) {
  const width = Math.max(1, Math.round(size[0])),
    height = Math.max(1, Math.round(size[1]));
  const page = browserLayout({ width, height, ...layout }).primary;
  const requested = Number.isFinite(layout.panelWidth) ? layout.panelWidth : 0;
  const panelWidth = Math.max(
    1,
    Math.min(width, Math.round(Math.max(0, Math.min(requested, width - page.x - 316)))),
  );
  const x = Math.max(0, width - panelWidth - Math.min(8, width - panelWidth));
  const y = Math.min(height - 1, page.y + 48);
  return { x, y, width: panelWidth, height: Math.max(1, height - y - Math.min(8, height - y - 1)) };
}
class SidePanelController {
  constructor(options) {
    Object.assign(this, options);
    this.states = new Map();
    this.gestures = new Map();
    this.current = null;
    this.sequence = 0;
  }
  key(context) {
    return JSON.stringify([context.profileId, context.extensionId]);
  }
  guard(context) {
    context.assertCurrent?.();
    const metadata = this.resolveExtension(context.profileId, context.extensionId);
    if (
      !metadata?.enabled ||
      metadata.generation !== context.generation ||
      !this.getProfile(context.profileId) ||
      this.getProfile(context.profileId).private
    )
      throw new Error('Expired or disabled extension context');
    if (!metadata.grants.permissions.includes('sidePanel')) throw new Error('Missing sidePanel permission');
    return metadata;
  }
  filename(context) {
    return path.join(this.profilePath(context.profileId), 'side-panels', context.extensionId + '.json');
  }
  state(context) {
    const metadata = this.guard(context),
      key = this.key(context);
    let state = this.states.get(key);
    if (!state || state.generation !== metadata.generation) {
      let saved = {};
      try {
        const bytes = fs.readFileSync(this.filename(context));
        if (bytes.length > 16384) throw Error('Panel state too large');
        saved = JSON.parse(bytes);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      const defaults = metadata.manifest.side_panel?.default_path;
      state = {
        generation: metadata.generation,
        options: { ...(defaults ? { path: resource(defaults) } : {}), enabled: !!defaults, ...saved.options },
        behavior: { openPanelOnActionClick: saved.behavior?.openPanelOnActionClick === true },
        tabs: new Map(),
      };
      if (state.options.path) resource(state.options.path);
      this.states.set(key, state);
    }
    return state;
  }
  persist(context, state) {
    this.guard(context);
    const filename = this.filename(context);
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    fs.writeFileSync(
      filename + '.tmp',
      JSON.stringify({ options: state.options, behavior: state.behavior }),
      { mode: 0o600 },
    );
    fs.renameSync(filename + '.tmp', filename);
  }
  tab(context, tabId) {
    if (!Number.isInteger(tabId) || tabId < 0) throw new Error('Invalid tab ID');
    return this.getTab(context.profileId, tabId);
  }
  options(context, tabId) {
    const state = this.state(context);
    if (tabId !== undefined) this.tab(context, tabId);
    return {
      ...state.options,
      ...(tabId !== undefined ? state.tabs.get(tabId) : {}),
      ...(tabId !== undefined ? { tabId } : {}),
    };
  }
  recordGesture(context) {
    this.guard(context);
    this.gestures.set(this.key(context), { generation: context.generation, expires: Date.now() + 1000 });
  }
  trackInput(contents, context) {
    const record = (_event, input) => {
      if (input?.type === 'keyDown' || input?.type === 'mouseDown') {
        try {
          this.recordGesture(context);
        } catch {}
      }
    };
    contents.on('before-input-event', record);
    contents.on('before-mouse-event', record);
  }
  async call(context, name, args = []) {
    const state = this.state(context),
      props = args[0] || {};
    if (!props || typeof props !== 'object' || Array.isArray(props))
      throw new Error('Invalid side panel properties');
    const allowed = {
      getOptions: ['tabId'],
      setOptions: ['tabId', 'path', 'enabled'],
      getPanelBehavior: [],
      setPanelBehavior: ['openPanelOnActionClick'],
      open: ['tabId', 'windowId'],
      close: ['tabId', 'windowId'],
      getLayout: [],
    }[name];
    if (!allowed || Object.keys(props).some((k) => !allowed.includes(k)))
      throw Error('Invalid side panel properties');
    if (name === 'getOptions') return this.options(context, props.tabId);
    if (name === 'getPanelBehavior') return { ...state.behavior };
    if (name === 'getLayout') return { side: 'right' };
    if (name === 'setPanelBehavior') {
      if (typeof props.openPanelOnActionClick !== 'boolean') throw Error('Invalid panel behavior');
      state.behavior = { openPanelOnActionClick: props.openPanelOnActionClick };
      this.persist(context, state);
      return;
    }
    if (name === 'setOptions') {
      if (props.tabId !== undefined) this.tab(context, props.tabId);
      if (props.enabled !== undefined && typeof props.enabled !== 'boolean')
        throw Error('Invalid enabled option');
      const next = {
        ...(props.tabId === undefined ? state.options : state.tabs.get(props.tabId)),
        ...(props.path !== undefined ? { path: resource(props.path) } : {}),
        enabled: props.enabled === undefined ? true : props.enabled,
      };
      if (props.tabId === undefined) {
        state.options = next;
        this.persist(context, state);
      } else state.tabs.set(props.tabId, next);
      const open = this.current;
      if (
        open &&
        this.key(open.context) === this.key(context) &&
        (props.tabId === undefined || props.tabId === open.tabId)
      ) {
        const current = this.options(context, open.tabId);
        if (!current.enabled || !current.path) this.destroy();
        else if (current.path !== open.path) await this.show(context, open.tabId, current);
      }
      this.reconcile();
      this.changed?.();
      return;
    }
    const window = this.getWindow();
    if (!window || window.isDestroyed() || (props.windowId !== undefined && props.windowId !== window.id))
      throw Error('Unknown browser window');
    if (props.tabId === undefined && props.windowId === undefined)
      throw Error('A tabId or windowId is required');
    if (props.tabId !== undefined) this.tab(context, props.tabId);
    if (this.activeProfile()?.id !== context.profileId) throw Error('Activate the extension profile first');
    if (name === 'close') {
      if (
        this.current &&
        this.key(this.current.context) === this.key(context) &&
        props.tabId !== undefined &&
        this.current.tabId === undefined
      )
        throw Error('Only the global panel is open');
      if (
        this.current &&
        this.key(this.current.context) === this.key(context) &&
        (props.tabId === undefined ? this.current.tabId === undefined : this.current.tabId === props.tabId)
      )
        this.destroy();
      return;
    }
    const gesture = this.gestures.get(this.key(context));
    this.gestures.delete(this.key(context));
    if (!gesture || gesture.generation !== context.generation || gesture.expires < Date.now())
      throw Error('Opening a side panel requires a user gesture');
    const requestedTabId = props.tabId;
    if (requestedTabId !== undefined && this.activeTabId(context.profileId) !== requestedTabId)
      throw Error('Activate the requested tab first');
    const tabId = state.tabs.has(requestedTabId) ? requestedTabId : undefined,
      options = this.options(context, tabId);
    if (!options.enabled || !options.path) throw Error('Side panel is disabled or has no page');
    return this.show(context, tabId, options);
  }
  async show(context, tabId, options) {
    this.guard(context);
    if (
      this.current &&
      this.key(this.current.context) === this.key(context) &&
      this.current.tabId === tabId &&
      this.current.path === options.path
    ) {
      this.current.openId = ++this.sequence;
      this.changed?.();
      return;
    }
    this.destroy(false);
    const view = new this.native.WebContentsView({
      webPreferences: {
        session: this.getSession(context.profileId),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        webSecurity: true,
      },
    });
    const entry = {
      context: {
        profileId: context.profileId,
        extensionId: context.extensionId,
        generation: context.generation,
      },
      openId: ++this.sequence,
      tabId,
      path: options.path,
      view,
      presentation: null,
    };
    this.current = entry;
    const valid = (target) => {
      try {
        const url = new URL(target);
        return (
          url.protocol === 'chrome-extension:' &&
          url.hostname === context.extensionId &&
          !url.pathname.startsWith('/zacro-')
        );
      } catch {
        return false;
      }
    };
    view.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    for (const event of ['will-navigate', 'will-redirect'])
      view.webContents.on(event, (e, target) => {
        if (!valid(target)) e.preventDefault();
      });
    view.webContents.on('did-navigate', (_event, target) => {
      if (!valid(target) && this.current === entry) this.destroy();
    });
    view.webContents.on('render-process-gone', () => {
      if (this.current === entry) this.destroy();
    });
    this.trackInput(view.webContents, entry.context);
    try {
      await view.webContents.loadURL(`chrome-extension://${context.extensionId}/${options.path}`);
      this.guard(context);
      if (this.current !== entry || this.activeProfile()?.id !== context.profileId)
        throw Error('Side panel lifecycle changed');
      this.changed?.();
    } catch (error) {
      if (this.current === entry) this.destroy();
      throw error;
    }
  }
  snapshot() {
    const e = this.current;
    if (!e) return null;
    return {
      openId: e.openId,
      extensionId: e.context.extensionId,
      profileId: e.context.profileId,
      generation: e.context.generation,
      tabId: e.tabId,
      title: this.resolveExtension(e.context.profileId, e.context.extensionId)?.manifest.name || 'Extension',
    };
  }
  arrange(layout) {
    if (!this.current) return;
    const e = this.current,
      window = this.getWindow();
    if (!window || window.isDestroyed()) return this.destroy();
    e.presentation = presentView(
      e.view,
      e.presentation,
      {
        bounds: panelBounds(window.getContentSize(), layout),
        visible: !!layout.extensionPanel && layout.panelWidth > 0 && !layout.overlay,
      },
      window.contentView,
    );
  }
  reconcile() {
    const e = this.current;
    if (!e) return;
    try {
      this.guard(e.context);
      if (
        this.activeProfile()?.id !== e.context.profileId ||
        (e.tabId !== undefined && this.activeTabId(e.context.profileId) !== e.tabId)
      )
        return this.destroy();
      if (e.tabId !== undefined) this.tab(e.context, e.tabId);
      else if (!this.options(e.context, this.activeTabId(e.context.profileId)).enabled) this.destroy();
    } catch {
      this.destroy();
    }
  }
  revoke(profileId, extensionId, remove = false) {
    const context = { profileId, extensionId };
    if (this.current && this.key(this.current.context) === this.key(context)) this.destroy();
    this.states.delete(this.key(context));
    this.gestures.delete(this.key(context));
    if (remove) fs.rmSync(this.filename(context), { force: true });
  }
  revokeProfile(profileId) {
    if (this.current?.context.profileId === profileId) this.destroy();
    for (const key of this.states.keys()) if (JSON.parse(key)[0] === profileId) this.states.delete(key);
    for (const key of this.gestures.keys()) if (JSON.parse(key)[0] === profileId) this.gestures.delete(key);
  }
  destroy(notify = true) {
    const e = this.current;
    if (!e) return;
    this.current = null;
    const parent = this.getWindow()?.contentView;
    if (e.presentation?.attached && parent) parent.removeChildView(e.view);
    if (!e.view.webContents.isDestroyed()) e.view.webContents.close();
    if (notify) this.changed?.();
  }
  close() {
    this.destroy();
    this.states.clear();
    this.gestures.clear();
  }
}
module.exports = { SidePanelController, panelBounds, sidePanelResource: resource };
