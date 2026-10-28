'use strict';

function createBrowserAdapter({
  store,
  views,
  getWindow,
  activeProfile,
  reserveView,
  ensureView,
  navigate,
  closeTab,
  reloadDocument,
  publish,
}) {
  const tabsFor = (profile) => store.state.tabs.filter((tab) => tab.profileId === profile && !tab.closed);
  const win = () => {
    const value = getWindow();
    if (!value || value.isDestroyed()) throw new Error('Browser window is closed.');
    return value;
  };
  function tabRecord(profile, id) {
    const record = tabsFor(profile).find((tab) => views.get(tab.id)?.contents.id === id);
    if (!record) throw new Error('Unknown profile tab.');
    return record;
  }
  function tabData(tab) {
    if (tab.closed) throw new Error('Unknown profile tab.');
    const entry = reserveView(tab),
      wc = entry.contents,
      active = store.state.activeTabId === tab.id;
    return {
      id: wc.id,
      windowId: win().id,
      index: tabsFor(tab.profileId).indexOf(tab),
      active,
      highlighted: active,
      pinned: !!tab.pinned,
      incognito: false,
      url: entry.requestedURL || tab.url,
      title: tab.title,
      status: wc.isLoading() ? 'loading' : 'complete',
      audible: wc.isCurrentlyAudible(),
      mutedInfo: { muted: wc.isAudioMuted() },
      muted: wc.isAudioMuted(),
      ...(entry.favicon ? { favIconUrl: entry.favicon } : {}),
    };
  }
  function targetWindow(id) {
    if (id !== undefined && id !== win().id && id !== -2) throw new Error('Unknown profile window.');
  }
  function canActivate(profile) {
    if (activeProfile()?.id !== profile) throw new Error('A hidden profile cannot take focus.');
  }
  function validateProps(props) {
    for (const key of ['active', 'pinned', 'muted', 'highlighted', 'bypassCache'])
      if (props[key] !== undefined && typeof props[key] !== 'boolean')
        throw new Error('Invalid tab property.');
    if (props.index !== undefined && (!Number.isInteger(props.index) || props.index < -1))
      throw new Error('Invalid tab index.');
  }
  function move(profile, ids, props, guard) {
    validateProps(props);
    targetWindow(props.windowId);
    if (!Number.isInteger(props.index)) throw new Error('Tab index is required.');
    if (new Set(ids).size !== ids.length) throw new Error('Duplicate tab IDs are not allowed.');
    const items = ids.map((id) => tabRecord(profile, id));
    const profileTabs = tabsFor(profile).filter((tab) => !items.includes(tab));
    const index = props.index === -1 ? profileTabs.length : Math.min(props.index, profileTabs.length);
    profileTabs.splice(index, 0, ...items);
    let cursor = 0;
    guard();
    store.state.tabs = store.state.tabs.map((tab) =>
      tab.profileId === profile && !tab.closed ? profileTabs[cursor++] : tab,
    );
    store.changed();
    return items.map(tabData);
  }
  async function create(profile, props, guard) {
    validateProps(props);
    targetWindow(props.windowId);
    if (props.active !== false) canActivate(profile);
    if (props.openerTabId !== undefined) tabRecord(profile, props.openerTabId);
    const space =
      store.state.spaces.find(
        (item) => item.id === store.state.activeSpaceId && item.profileId === profile,
      ) || store.state.spaces.find((item) => item.profileId === profile);
    if (!space) throw new Error('Profile has no Space.');
    guard();
    const ownPage = props.url?.startsWith('chrome-extension:');
    const tab = store.dispatch('tab:create', {
      spaceId: space.id,
      url: ownPage ? undefined : props.url,
      active: props.active !== false,
    });
    if (ownPage) store.dispatch('tab:extension-page', { id: tab.id, url: props.url });
    const entry = reserveView(tab);
    if (props.pinned) store.dispatch('tab:pin', { id: tab.id });
    if (props.index !== undefined) move(profile, [entry.contents.id], props, guard);
    guard();
    if (props.url) navigate(entry, props.url);
    return tabData(tab);
  }
  const tabs = {
    query: (profile, _query, guard) => {
      guard();
      return tabsFor(profile).map(tabData);
    },
    get: (profile, id, guard) => {
      guard();
      return tabData(tabRecord(profile, id));
    },
    create,
    update: async (profile, id, props, guard) => {
      validateProps(props);
      const tab = tabRecord(profile, id),
        entry = reserveView(tab);
      if (props.highlighted === false)
        throw new Error('The active tab cannot be unhighlighted independently.');
      if (props.active || props.highlighted) {
        canActivate(profile);
        guard();
        store.dispatch('tab:activate', { id: tab.id });
      }
      guard();
      if (props.pinned !== undefined && props.pinned !== tab.pinned)
        store.dispatch('tab:pin', { id: tab.id });
      if (props.muted !== undefined) entry.contents.setAudioMuted(props.muted);
      if (props.url) {
        store.dispatch(props.url.startsWith('chrome-extension:') ? 'tab:extension-page' : 'tab:update', {
          id: tab.id,
          url: props.url,
        });
        guard();
        navigate(entry, props.url);
      }
      publish();
      return tabData(tab);
    },
    remove: async (profile, ids, guard) => {
      for (const id of ids) {
        const tab = tabRecord(profile, id);
        guard();
        if (!(await closeTab(tab.id))) throw new Error('The page kept its unsaved changes.');
      }
    },
    reload: (profile, id, props, guard) => {
      validateProps(props);
      const tab = tabRecord(profile, id),
        entry = ensureView(tab.id);
      guard();
      if (!entry.dormant) props.bypassCache ? entry.contents.reloadIgnoringCache() : entry.contents.reload();
    },
    duplicate: (profile, id, guard) => {
      const tab = tabRecord(profile, id);
      return create(
        profile,
        {
          url: tab.url === 'zacro://newtab' ? undefined : tab.url,
          active: activeProfile()?.id === profile,
          pinned: tab.pinned,
        },
        guard,
      );
    },
    move,
  };
  function windowData(profile, info = {}) {
    const window = win(),
      bounds = window.getBounds();
    return {
      id: window.id,
      type: 'normal',
      focused: activeProfile()?.id === profile && window.isFocused(),
      incognito: false,
      state: window.isFullScreen()
        ? 'fullscreen'
        : window.isMinimized()
          ? 'minimized'
          : window.isMaximized()
            ? 'maximized'
            : 'normal',
      left: bounds.x,
      top: bounds.y,
      width: bounds.width,
      height: bounds.height,
      ...(info.populate ? { tabs: tabsFor(profile).map(tabData) } : {}),
    };
  }
  const windows = {
    get: (profile, id, info, guard) => {
      guard();
      targetWindow(id);
      return windowData(profile, info);
    },
    getCurrent: (profile, info, guard) => {
      guard();
      return windowData(profile, info);
    },
    getAll: (profile, info, guard) => {
      guard();
      return !info.windowTypes || info.windowTypes.includes('normal') ? [windowData(profile, info)] : [];
    },
    update: (profile, id, props, guard) => {
      targetWindow(id);
      canActivate(profile);
      for (const key of ['left', 'top', 'width', 'height'])
        if (
          props[key] !== undefined &&
          (!Number.isInteger(props[key]) ||
            Math.abs(props[key]) > 32768 ||
            (['width', 'height'].includes(key) && props[key] < 200))
        )
          throw new Error('Invalid window bounds.');
      if (props.focused !== undefined && typeof props.focused !== 'boolean')
        throw new Error('Invalid window focus.');
      if (props.state && !['normal', 'minimized', 'maximized', 'fullscreen'].includes(props.state))
        throw new Error('Invalid window state.');
      guard();
      const window = win();
      if (props.state === 'normal') {
        window.setFullScreen(false);
        window.unmaximize();
        window.restore();
      }
      if (props.state === 'minimized') window.minimize();
      if (props.state === 'maximized') window.maximize();
      if (props.state === 'fullscreen') window.setFullScreen(true);
      const bounds = {};
      for (const [key, target] of [
        ['left', 'x'],
        ['top', 'y'],
        ['width', 'width'],
        ['height', 'height'],
      ])
        if (props[key] !== undefined) bounds[target] = props[key];
      if (Object.keys(bounds).length) window.setBounds(bounds);
      if (props.focused === true) window.focus();
      if (props.focused === false) window.blur();
      return windowData(profile);
    },
  };
  return {
    tabs,
    windows,
    tabData,
    activeTabId: (profile) => {
      const tab = tabsFor(profile).find((item) => item.id === store.state.activeTabId);
      if (!tab) throw new Error('There is no active tab in this profile.');
      return reserveView(tab).contents.id;
    },
    documents: (profile) =>
      [...views.values()].filter(
        (entry) =>
          entry.profileId === profile &&
          !entry.dormant &&
          !entry.contents.isDestroyed() &&
          /^https?:/.test(entry.contents.getURL()),
      ),
    reloadDocument,
  };
}
module.exports = { createBrowserAdapter };
