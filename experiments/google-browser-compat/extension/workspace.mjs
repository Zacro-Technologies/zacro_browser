export const PREFERENCE_KEY = 'zacroWorkspacePreferences';
export const GROUP_COLORS = Object.freeze([
  'grey',
  'blue',
  'red',
  'yellow',
  'green',
  'pink',
  'purple',
  'cyan',
  'orange',
]);
const appearances = new Set(['system', 'light', 'dark']);

export function preferences(value) {
  return { appearance: appearances.has(value?.appearance) ? value.appearance : 'system' };
}

export function webAddress(value) {
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u001f\u007f]/u.test(value))
    throw new Error('Enter a complete http:// or https:// address.');
  let url;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error('Enter a complete http:// or https:// address.');
  }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname || url.username || url.password)
    throw new Error('Use an HTTP or HTTPS address without embedded credentials.');
  return url.href;
}

export function tabLabel(tab) {
  return String(tab.title || 'Untitled tab')
    .replace(/[\u0000-\u001f\u007f]/gu, ' ')
    .slice(0, 180);
}

export function tabHost(tab) {
  try {
    const url = new URL(tab.url || tab.pendingUrl);
    return ['http:', 'https:'].includes(url.protocol) ? url.hostname.replace(/^www\./u, '') : 'Browser page';
  } catch {
    return 'Browser page';
  }
}

// The projection never persists native session IDs or page metadata. Workspaces
// are the browser's existing groups, not an independent tab/session database.
export function project(snapshot, { filter = 'all', query = '' } = {}) {
  const terms = String(query).trim().toLocaleLowerCase();
  const matches = (tab) => !terms || `${tabLabel(tab)} ${tabHost(tab)}`.toLocaleLowerCase().includes(terms);
  const groupIds = new Set(snapshot.groups.map((group) => group.id));
  const selected = filter === 'ungrouped' || groupIds.has(filter) ? filter : 'all';
  const pins = snapshot.tabs.filter((tab) => tab.pinned && matches(tab));
  const regular = snapshot.tabs.filter((tab) => !tab.pinned && matches(tab));
  const sections = [];
  for (const group of snapshot.groups) {
    if (selected !== 'all' && selected !== group.id) continue;
    const tabs = regular.filter((tab) => tab.groupId === group.id);
    if (tabs.length || !terms) sections.push({ ...group, title: group.title || 'Untitled workspace', tabs });
  }
  if (selected === 'all' || selected === 'ungrouped') {
    const tabs = regular.filter((tab) => !groupIds.has(tab.groupId));
    if (tabs.length) sections.push({ id: -1, title: 'Ungrouped', color: 'grey', collapsed: false, tabs });
  }
  return {
    selected,
    pins,
    sections,
    count: pins.length + sections.reduce((sum, group) => sum + group.tabs.length, 0),
  };
}

export function createWorkspace(api, windowId) {
  if (!Number.isInteger(windowId) || windowId < 0) throw new Error('A regular browser window is required.');
  const owns = (tab) => tab && tab.windowId === windowId && tab.incognito === false;
  async function ownTab(id) {
    if (!Number.isInteger(id) || id < 0) throw new Error('Choose an available tab.');
    const tab = await api.tabs.get(id);
    if (!owns(tab)) throw new Error('That tab is outside this regular browser window.');
    return tab;
  }
  async function ownGroup(id) {
    if (!Number.isInteger(id) || id < 0) throw new Error('Choose an available workspace.');
    const group = await api.tabGroups.get(id);
    if (group.windowId !== windowId) throw new Error('That workspace is outside this browser window.');
    return group;
  }
  function groupFields(payload) {
    const title = typeof payload.title === 'string' ? payload.title.trim() : '';
    if (!title || title.length > 48 || /[\u0000-\u001f\u007f]/u.test(title))
      throw new Error('Give the workspace a name of 1–48 characters.');
    if (!GROUP_COLORS.includes(payload.color)) throw new Error('Choose a workspace color.');
    return { title, color: payload.color };
  }
  return {
    windowId,
    async read() {
      const [tabs, groups] = await Promise.all([
        api.tabs.query({ windowId }),
        api.tabGroups.query({ windowId }),
      ]);
      const visible = tabs.filter(owns).sort((a, b) => a.index - b.index);
      const order = (group) => visible.findIndex((tab) => tab.groupId === group.id);
      return {
        tabs: visible,
        groups: groups
          .filter((group) => group.windowId === windowId)
          .map((group) => ({ ...group, color: GROUP_COLORS.includes(group.color) ? group.color : 'grey' }))
          .sort((a, b) => order(a) - order(b)),
      };
    },
    async loadPreferences() {
      const saved = await api.storage.local.get(PREFERENCE_KEY);
      return preferences(saved[PREFERENCE_KEY]);
    },
    async savePreferences(value) {
      const next = preferences(value);
      await api.storage.local.set({ [PREFERENCE_KEY]: next });
      return next;
    },
    async dispatch(action, payload = {}) {
      switch (action) {
        case 'create':
          return api.tabs.create({ windowId, url: webAddress(payload.url), active: true });
        case 'activate': {
          const tab = await ownTab(payload.tabId);
          return api.tabs.update(tab.id, { active: true });
        }
        case 'pin': {
          const tab = await ownTab(payload.tabId);
          return api.tabs.update(tab.id, { pinned: !tab.pinned });
        }
        case 'move': {
          const tab = await ownTab(payload.tabId);
          if (tab.pinned) throw new Error('Unpin the tab before moving it into a workspace.');
          if (payload.groupId === -1) return api.tabs.ungroup([tab.id]);
          const group = await ownGroup(payload.groupId);
          return api.tabs.group({ tabIds: [tab.id], groupId: group.id });
        }
        case 'create-group': {
          const fields = groupFields(payload);
          const tab = await ownTab(payload.tabId);
          if (tab.pinned) throw new Error('Choose an unpinned tab to start the workspace.');
          const id = await api.tabs.group({ tabIds: [tab.id], createProperties: { windowId } });
          await api.tabGroups.update(id, { ...fields, collapsed: false });
          return { groupId: id };
        }
        case 'edit-group': {
          const fields = groupFields(payload);
          const group = await ownGroup(payload.groupId);
          return api.tabGroups.update(group.id, fields);
        }
        case 'collapse-group': {
          const group = await ownGroup(payload.groupId);
          return api.tabGroups.update(group.id, { collapsed: !group.collapsed });
        }
        default:
          throw new Error('This workspace action is unavailable.');
      }
    },
  };
}
