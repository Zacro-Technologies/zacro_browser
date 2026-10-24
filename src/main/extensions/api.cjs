'use strict';
const { matches, permissionDetails, optionalGrants } = require('./permissions.cjs');
const clone = (value) => structuredClone(value);
const trusted = (context) => context.kind !== 'content-script';
const reserved = new Set([
  'F5',
  'F6',
  'F11',
  'F12',
  'Alt+Tab',
  'Alt+Left',
  'Alt+Right',
  'Alt+ArrowLeft',
  'Alt+ArrowRight',
  'Ctrl+Alt+Delete',
  'Command+Space',
  'Ctrl+Space',
]);
for (const mod of ['Ctrl', 'Command', 'MacCtrl'])
  for (const key of [
    'T',
    'W',
    'N',
    'L',
    'R',
    'Q',
    'F',
    'D',
    'K',
    'H',
    'J',
    'B',
    ',',
    'Comma',
    'P',
    'Enter',
    '+',
    'Plus',
    '-',
    'Minus',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'Tab',
    'M',
  ]) {
    reserved.add(mod + '+' + key);
    reserved.add(mod + '+Shift+' + key);
  }
for (const mod of ['Ctrl', 'Command', 'MacCtrl']) reserved.add(mod + '+Shift+I');

function object(value = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid properties');
  return value;
}
function keys(value, allowed) {
  object(value);
  if (Object.keys(value).some((key) => !allowed.includes(key))) throw new Error('Unsupported properties');
  return value;
}
function integer(value) {
  if (!Number.isInteger(value) || value < 0) throw new Error('Invalid tab or window ID');
  return value;
}
function resource(context, path) {
  if (typeof path !== 'string' || path.includes('\\')) throw new Error('Invalid extension resource');
  const url = new URL(path, `chrome-extension://${context.extensionId}/`);
  if (
    url.protocol !== 'chrome-extension:' ||
    url.hostname !== context.extensionId ||
    url.pathname === '/zacro-compat-transport.html'
  )
    throw new Error('Invalid extension resource');
  return url.href;
}
function navigation(context, url) {
  const parsed = new URL(url);
  if (!['http:', 'https:'].includes(parsed.protocol)) return resource(context, url);
  if (parsed.username || parsed.password) throw new Error('Invalid navigation URL');
  return parsed.href;
}
class ExtensionAPI {
  constructor(options) {
    Object.assign(this, options);
    this.states = new Map();
  }
  guard(context) {
    context.assertCurrent?.();
    const metadata = this.resolveExtension(context.profileId, context.extensionId);
    if (!metadata?.enabled || metadata.generation !== context.generation)
      throw new Error('Expired or disabled extension context');
    return metadata;
  }
  context(profileId, extensionId) {
    const metadata = this.resolveExtension(profileId, extensionId);
    if (!metadata?.enabled) throw new Error('Extension disabled');
    return { profileId, extensionId, metadata, generation: metadata.generation, kind: 'host' };
  }
  state(context) {
    const metadata = this.guard(context),
      key = JSON.stringify([context.profileId, context.extensionId]);
    let state = this.states.get(key);
    if (!state || state.generation !== metadata.generation) {
      state = {
        profileId: context.profileId,
        extensionId: context.extensionId,
        generation: metadata.generation,
        menus: new Map(),
        actions: new Map(),
        active: new Map(),
        gesture: 0,
      };
      this.states.set(key, state);
    }
    return state;
  }
  async host(context, group, method, args) {
    const guard = () => this.guard(context);
    guard();
    if (typeof this[group]?.[method] !== 'function') throw new Error(`Unsupported API: ${group}.${method}`);
    const result = await this[group][method](context.profileId, ...args, guard);
    guard();
    return result;
  }
  async tab(context, id) {
    const result = await this.host(context, 'tabs', 'get', [integer(id)]);
    if (!result || result.id !== id) throw new Error('Unknown profile tab');
    return result;
  }
  allowed(context, tab) {
    const grants = this.guard(context).grants;
    const state = this.state(context),
      active = state.active.get(tab.id);
    if (active && active.url !== tab.url) state.active.delete(tab.id);
    return (
      grants.permissions.includes('tabs') ||
      grants.origins.some((pattern) => matches(pattern, tab.url)) ||
      (active && active.url === tab.url)
    );
  }
  sanitize(context, tab) {
    if (!tab) return tab;
    const result = clone(tab);
    if (!this.allowed(context, tab))
      for (const key of ['url', 'pendingUrl', 'title', 'favIconUrl']) delete result[key];
    return result;
  }
  actionState(profileId, id, tabId) {
    const context = this.context(profileId, id),
      state = this.state(context),
      manifest = context.metadata.manifest,
      declared = manifest.action || manifest.browser_action || {};
    return {
      title: declared.default_title || manifest.name || '',
      popup: declared.default_popup || '',
      icon: declared.default_icon || null,
      badgeText: '',
      badgeBackgroundColor: '#000000',
      enabled: true,
      ...clone(state.actions.get(-1) || {}),
      ...clone(state.actions.get(tabId) || {}),
    };
  }
  async actionChanged(context, tabId) {
    const guard = () => this.guard(context);
    guard();
    await this.onActionChanged?.(
      context.profileId,
      context.extensionId,
      tabId,
      this.actionState(context.profileId, context.extensionId, tabId),
      guard,
    );
    guard();
  }
  commandsState(profileId, id) {
    const context = this.context(profileId, id),
      commands = context.metadata.manifest.commands || {};
    const used = new Set();
    const installations = this.listExtensions?.(profileId)?.map((record) => ({
      profileId,
      extensionId: record.id,
    })) || [...this.states.values()];
    for (const state of installations)
      if (state.profileId === profileId && state.extensionId !== id) {
        const metadata = this.resolveExtension(profileId, state.extensionId);
        if (metadata?.enabled)
          for (const command of Object.values(metadata.manifest.commands || {})) {
            const key = this.shortcut(command);
            if (key) used.add(key);
          }
      }
    return Object.entries(commands).map(([name, command]) => {
      const requested = this.shortcut(command);
      const conflict = reserved.has(requested) || used.has(requested);
      used.add(requested);
      return {
        name,
        description: command.description || '',
        shortcut: conflict ? '' : requested,
        requestedShortcut: requested,
        status: conflict ? 'conflict' : requested ? 'assigned' : 'unassigned',
      };
    });
  }
  shortcut(command) {
    const value =
      command.suggested_key?.[
        process.platform === 'darwin' ? 'mac' : process.platform === 'win32' ? 'windows' : 'linux'
      ] ||
      command.suggested_key?.default ||
      '';
    if (typeof value !== 'string' || !value) return '';
    const parts = value.split('+'),
      key = parts.pop();
    if (
      !key ||
      parts.some((part) => !['Command', 'Ctrl', 'MacCtrl', 'Alt', 'Shift'].includes(part)) ||
      new Set(parts).size !== parts.length
    )
      return '';
    if (
      !/^(?:[A-Z0-9]|F(?:[1-9]|1[0-2])|Comma|Period|Plus|Minus|Space|Tab|Enter|Insert|Delete|Home|End|PageUp|PageDown|Up|Down|Left|Right|ArrowLeft|ArrowRight|MediaNextTrack|MediaPrevTrack|MediaPlayPause|MediaStop|,|-)$/.test(
        key,
      )
    )
      return '';
    const modifiers = new Set(
      parts.map((part) =>
        part === 'MacCtrl' ? 'Ctrl' : part === 'Ctrl' && process.platform === 'darwin' ? 'Command' : part,
      ),
    );
    if (
      ![...modifiers].some((part) => ['Command', 'Ctrl', 'Alt'].includes(part)) &&
      !/^Media|^F\d+$/.test(key)
    )
      return '';
    return [...['Command', 'Ctrl', 'Alt', 'Shift'].filter((part) => modifiers.has(part)), key].join('+');
  }
  async gesture(context, tabId) {
    const state = this.state(context),
      tab = await this.tab(context, tabId);
    this.guard(context);
    state.gesture = Date.now() + 5000;
    if (context.metadata.grants.permissions.includes('activeTab')) state.active.set(tabId, { url: tab.url });
    return tab;
  }
  async activateAction(profileId, id, tabId) {
    const context = this.context(profileId, id),
      tab = await this.gesture(context, tabId),
      action = this.actionState(profileId, id, tabId);
    if (!action.enabled) return false;
    if (action.popup)
      await this.host(context, 'dialogs', 'openView', [
        id,
        { kind: 'action', url: resource(context, action.popup), tabId, generation: context.generation },
      ]);
    else this.emit?.(profileId, id, 'action.onClicked', [this.sanitize(context, tab)]);
    return true;
  }
  async dispatchCommand(profileId, id, name, tabId) {
    const context = this.context(profileId, id),
      command = this.commandsState(profileId, id).find((item) => item.name === name);
    if (!command || command.status !== 'assigned') throw new Error('Command is unassigned or conflicts');
    if (name === '_execute_action' || name === '_execute_browser_action')
      return this.activateAction(profileId, id, tabId);
    const tab = await this.gesture(context, tabId);
    this.emit?.(profileId, id, 'commands.onCommand', [name, this.sanitize(context, tab)]);
  }
  menuItems(profileId, id) {
    try {
      return [...this.state(this.context(profileId, id)).menus.values()].map(clone);
    } catch {
      return [];
    }
  }
  async clickMenu(profileId, id, itemId, info, tabId) {
    const context = this.context(profileId, id),
      item = this.state(context).menus.get(itemId);
    if (!item || item.enabled === false) throw new Error('Unknown menu');
    const tab = await this.gesture(context, tabId);
    this.emit?.(profileId, id, 'contextMenus.onClicked', [
      { ...clone(info), menuItemId: itemId },
      this.sanitize(context, tab),
    ]);
  }
  publish(profileId, event, args) {
    if (
      ![
        'tabs.onCreated',
        'tabs.onUpdated',
        'tabs.onActivated',
        'tabs.onRemoved',
        'windows.onFocusChanged',
      ].includes(event)
    )
      throw new Error('Unsupported event');
    for (const record of this.listExtensions?.(profileId) || []) {
      try {
        this.state(this.context(profileId, record.id));
      } catch {}
    }
    for (const state of this.states.values())
      if (state.profileId === profileId) {
        try {
          const context = this.context(profileId, state.extensionId);
          if (context.generation !== state.generation) continue;
          let output = clone(args);
          if (event === 'tabs.onCreated') output = [this.sanitize(context, args[0])];
          if (event === 'tabs.onUpdated') {
            if (args[1].status === 'loading' || Object.hasOwn(args[1], 'url')) state.active.delete(args[0]);
            output = [args[0], clone(args[1]), this.sanitize(context, args[2])];
            if (!this.allowed(context, args[2]))
              for (const key of ['url', 'title', 'favIconUrl']) delete output[1][key];
          }
          if (event === 'tabs.onRemoved') state.active.delete(args[0]);
          this.emit?.(profileId, state.extensionId, event, output);
        } catch {
          /* Revoked generations receive no events. */
        }
      }
  }
  async call(context, method, args) {
    const metadata = this.guard(context),
      state = this.state(context);
    if (!Array.isArray(args)) throw new Error('Invalid arguments');
    if (method.startsWith('storage.sync.')) {
      const name = method.slice(13);
      if (!['get', 'getKeys', 'getBytesInUse', 'set', 'remove', 'clear', 'setAccessLevel'].includes(name))
        throw new Error('Unsupported storage method');
      if (!metadata.grants.permissions.includes('storage')) throw new Error('Missing storage permission');
      if (!this.storage?.call) throw new Error('Storage unavailable');
      const result = await this.storage.call(context, name, args);
      this.guard(context);
      return result;
    }
    if (!trusted(context)) throw new Error('Trusted extension contexts only');
    if (method.split('.').length !== 2) throw new Error(`Unsupported API: ${method}`);
    const [group, name] = method.split('.');
    if (group === 'tabs') {
      if (name === 'get') return this.sanitize(context, await this.tab(context, args[0]));
      if (name === 'getCurrent') {
        const id = context.sourceContents?.id || context.sender?.top?.webContents?.id;
        return id ? this.sanitize(context, await this.tab(context, id).catch(() => undefined)) : undefined;
      }
      if (name === 'query') {
        const query = keys(args[0] || {}, [
          'active',
          'currentWindow',
          'lastFocusedWindow',
          'windowId',
          'index',
          'url',
          'title',
          'status',
          'pinned',
          'audible',
          'muted',
          'highlighted',
        ]);
        const tabs = await this.host(context, 'tabs', 'query', [query]);
        return tabs
          .map((tab) => this.sanitize(context, tab))
          .filter((tab) =>
            Object.entries(query).every(
              ([key, value]) =>
                ['currentWindow', 'lastFocusedWindow'].includes(key) ||
                (key === 'url'
                  ? (Array.isArray(value) ? value : [value]).some((pattern) => matches(pattern, tab.url))
                  : key === 'title'
                    ? typeof tab.title === 'string' &&
                      new RegExp(
                        '^' +
                          value
                            .split('*')
                            .map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
                            .join('.*') +
                          '$',
                      ).test(tab.title)
                    : tab[key] === value),
            ),
          );
      }
      if (name === 'create') {
        const props = keys({ ...object(args[0]) }, [
          'url',
          'active',
          'index',
          'pinned',
          'windowId',
          'openerTabId',
        ]);
        if (props.url) props.url = navigation(context, props.url);
        return this.sanitize(context, await this.host(context, 'tabs', 'create', [props]));
      }
      if (name === 'update') {
        let [id, props] = args;
        if (typeof id === 'object') {
          props = id;
          id = (await this.call(context, 'tabs.query', [{ active: true, currentWindow: true }]))[0]?.id;
        }
        await this.tab(context, id);
        props = keys({ ...object(props) }, ['url', 'active', 'pinned', 'muted', 'highlighted']);
        if (props.url) {
          try {
            props.url = navigation(context, props.url);
          } catch {
            throw new Error('Unsupported navigation URL');
          }
        }
        return this.sanitize(context, await this.host(context, 'tabs', 'update', [id, props]));
      }
      if (['reload', 'duplicate'].includes(name)) {
        const propertiesFirst = name === 'reload' && typeof args[0] === 'object';
        const id =
          (propertiesFirst ? undefined : args[0]) ??
          (await this.call(context, 'tabs.query', [{ active: true, currentWindow: true }]))[0]?.id;
        await this.tab(context, id);
        const values =
          name === 'reload' ? [id, keys((propertiesFirst ? args[0] : args[1]) || {}, ['bypassCache'])] : [id];
        const result = await this.host(context, 'tabs', name, values);
        return name === 'duplicate' ? this.sanitize(context, result) : result;
      }
      if (['remove', 'move'].includes(name)) {
        const ids = Array.isArray(args[0]) ? args[0] : [args[0]];
        for (const id of ids) await this.tab(context, id);
        const result = await this.host(
          context,
          'tabs',
          name,
          name === 'move' ? [ids, keys(args[1], ['index', 'windowId'])] : [ids],
        );
        if (name !== 'move') return result;
        const moved = (Array.isArray(result) ? result : [result]).map((tab) => this.sanitize(context, tab));
        return Array.isArray(args[0]) ? moved : moved[0];
      }
    }
    if (group === 'windows' && ['get', 'getCurrent', 'getAll', 'update'].includes(name)) {
      const props = keys(
        args[name === 'get' || name === 'update' ? 1 : 0] || {},
        name === 'update'
          ? ['focused', 'state', 'left', 'top', 'width', 'height']
          : ['populate', 'windowTypes'],
      );
      const result = await this.host(
        context,
        'windows',
        name,
        name === 'get' || name === 'update' ? [integer(args[0]), props] : [props],
      );
      const sanitize = (window) => ({
        ...window,
        ...(window.tabs ? { tabs: window.tabs.map((tab) => this.sanitize(context, tab)) } : {}),
      });
      return Array.isArray(result) ? result.map(sanitize) : sanitize(result);
    }
    if (method === 'runtime.openOptionsPage') {
      const page = metadata.manifest.options_ui?.page || metadata.manifest.options_page;
      if (!page) throw new Error('No options page declared');
      await this.host(context, 'dialogs', 'openView', [
        context.extensionId,
        { kind: 'options', url: resource(context, page), generation: context.generation },
      ]);
      return;
    }
    if (group === 'action' || group === 'browserAction') {
      if (!metadata.manifest.action && !metadata.manifest.browser_action)
        throw new Error('No action declared');
      const props = ['enable', 'disable'].includes(name) ? {} : object(args[0] || {}),
        tabId = ['enable', 'disable'].includes(name) ? (args[0] ?? -1) : (props.tabId ?? -1);
      if (tabId !== -1) await this.tab(context, tabId);
      const fields = {
        Title: 'title',
        Popup: 'popup',
        BadgeText: 'badgeText',
        BadgeBackgroundColor: 'badgeBackgroundColor',
        BadgeTextColor: 'badgeTextColor',
        Icon: 'icon',
      };
      if (['enable', 'disable'].includes(name)) {
        state.actions.set(tabId, { ...state.actions.get(tabId), enabled: name === 'enable' });
        await this.actionChanged(context, tabId);
        return;
      }
      const field = fields[name.slice(3)];
      if (field && name.startsWith('get'))
        return this.actionState(context.profileId, context.extensionId, tabId)[field];
      if (field && name.startsWith('set')) {
        let value =
          props[
            field === 'badgeText'
              ? 'text'
              : field.startsWith('badge')
                ? 'color'
                : field === 'icon'
                  ? 'path'
                  : field
          ];
        if (field === 'badgeBackgroundColor' || field === 'badgeTextColor') {
          if (
            !(typeof value === 'string' && /^(#[0-9a-f]{3,8}|[a-z]{1,30})$/i.test(value)) &&
            !(
              Array.isArray(value) &&
              value.length === 4 &&
              value.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)
            )
          )
            throw new Error('Invalid badge color');
        }
        if (field === 'popup' && value) resource(context, value);
        if (field === 'icon') {
          if (props.imageData !== undefined || value === undefined)
            throw new Error('Unsupported imageData icon; use a packaged icon path');
          if (typeof value === 'string') resource(context, value);
          else {
            object(value);
            for (const file of Object.values(value)) resource(context, file);
          }
        } else if (!['badgeBackgroundColor', 'badgeTextColor'].includes(field) && typeof value !== 'string')
          throw new Error('Invalid action value');
        state.actions.set(tabId, { ...state.actions.get(tabId), [field]: clone(value) });
        await this.actionChanged(context, tabId);
        return;
      }
    }
    if (group === 'contextMenus') {
      if (!metadata.grants.permissions.includes('contextMenus'))
        throw new Error('Missing contextMenus permission');
      if (name === 'create' || name === 'update') {
        const props = keys({ ...object(args[name === 'create' ? 0 : 1]) }, [
          'id',
          'title',
          'type',
          'contexts',
          'enabled',
          'checked',
          'parentId',
          'documentUrlPatterns',
          'targetUrlPatterns',
          'visible',
        ]);
        const id = name === 'create' ? props.id || `zacro-${state.menus.size + 1}` : args[0];
        if ((name === 'create' && state.menus.has(id)) || (name === 'update' && !state.menus.has(id)))
          throw new Error('Invalid menu ID');
        if (props.contexts?.some((value) => !['page', 'link', 'selection'].includes(value)))
          throw new Error('Unsupported menu context');
        if (props.type && !['normal', 'separator', 'checkbox', 'radio'].includes(props.type))
          throw new Error('Unsupported menu type');
        if (props.parentId !== undefined && !state.menus.has(props.parentId))
          throw new Error('Unknown parent menu');
        state.menus.set(id, { ...state.menus.get(id), ...props, id });
        await this.host(context, 'menus', 'changed', [
          context.extensionId,
          this.menuItems(context.profileId, context.extensionId),
        ]);
        return name === 'create' ? id : undefined;
      }
      if (name === 'remove' || name === 'removeAll') {
        if (name === 'remove' && !state.menus.delete(args[0])) throw new Error('Unknown menu');
        if (name === 'removeAll') state.menus.clear();
        await this.host(context, 'menus', 'changed', [
          context.extensionId,
          this.menuItems(context.profileId, context.extensionId),
        ]);
        return;
      }
    }
    if (method === 'commands.getAll') return this.commandsState(context.profileId, context.extensionId);
    if (group === 'permissions') {
      const grants = metadata.grants;
      if (name === 'getAll') return clone(grants);
      const details = permissionDetails(args[0]);
      if (name === 'contains')
        return ['permissions', 'origins'].every((key) =>
          details[key].every((value) => grants[key].includes(value)),
        );
      if (name === 'request' || name === 'remove') {
        const next = optionalGrants(
          metadata.originalManifest || metadata.manifest,
          grants,
          details,
          name === 'remove',
        );
        if (name === 'request') {
          if (state.gesture < Date.now()) throw new Error('Permission request requires a user gesture');
          state.gesture = 0;
          if (
            (await this.host(context, 'dialogs', 'requestPermissions', [context.extensionId, details])) !==
            true
          )
            return false;
        }
        if (typeof this.changePermissions !== 'function')
          throw new Error('Native permission rebuild unavailable');
        this.guard(context);
        const result = await this.changePermissions(context.profileId, context.extensionId, next, () =>
          this.guard(context),
        );
        const changed = Object.fromEntries(
          ['permissions', 'origins'].map((key) => [
            key,
            name === 'remove'
              ? grants[key].filter((value) => !next[key].includes(value))
              : next[key].filter((value) => !grants[key].includes(value)),
          ]),
        );
        if (changed.permissions.length || changed.origins.length)
          this.emit?.(
            context.profileId,
            context.extensionId,
            name === 'remove' ? 'permissions.onRemoved' : 'permissions.onAdded',
            [changed],
          );
        // Reload intentionally destroys the caller's generation. Its promise may
        // disconnect; durable manager state is the authoritative completion.
        return result?.status !== 'pending-reload';
      }
    }
    throw new Error(`Unsupported API: ${method}`);
  }
}
module.exports = { ExtensionAPI };
