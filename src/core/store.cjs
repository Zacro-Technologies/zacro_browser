'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { EventEmitter } = require('node:events');
const { sanitizeOverrides } = require('./shortcuts.cjs');
const { cleanNavigationHistory } = require('./navigation-history.cjs');
const { cleanSplitGroups } = require('./split-groups.cjs');
const { normalizeSiteSearches } = require('./site-search.js');
const {
  DEFAULT_ARCHIVE_HOURS,
  validArchiveHours,
  defaultArchiveProfile,
  normalizeDefaultArchive,
  archiveHours,
  archiveCandidate,
} = require('./archive.cjs');

const MAX_TABS = 1000;
const MAX_HISTORY = 20000;
const MAX_ARCHIVE = 1000;
const RECOVERY_PURGE_ACTIONS = new Set([
  'history:clear',
  'permission:clear',
  'archive:clear',
  'profile:delete',
]);
const THEMES = new Set(['system', 'light', 'dark']);
const SPACE_ICONS = new Set([
  'circle',
  'briefcase',
  'home',
  'code',
  'book',
  'leaf',
  'star',
  'heart',
  'globe',
  'coffee',
  'music',
  'moon',
  'plane',
  'camera',
  'gamepad',
  'palette',
  'beaker',
  'rocket',
  'compass',
  'mountain',
  'flame',
  'cloud',
  'bolt',
  'diamond',
  'flower',
  'smile',
  'headphones',
  'calendar',
  'film',
  'building',
  'bag',
  'terminal',
  'mail',
  'shield',
  'sun',
  'monitor',
  'eye',
  'folder',
]);
const DEFAULT_SPACE_THEME = Object.freeze({
  secondaryColor: '#b695b8',
  gradient: 50,
  vibrancy: 0,
  grain: 0,
  opacity: 100,
  blur: 0,
});
const SEARCH = Object.freeze({
  duckduckgo: 'https://duckduckgo.com/?q=',
  google: 'https://www.google.com/search?q=',
  bing: 'https://www.bing.com/search?q=',
  brave: 'https://search.brave.com/search?q=',
});
const id = (prefix) => `${prefix}-${randomUUID()}`;
const clone = (value) => structuredClone(value);
const str = (value, max = 200) => (typeof value === 'string' ? value.trim().slice(0, max) : '');
const color = (value) => (/^#[\da-f]{6}$/i.test(value || '') ? value : '#9d4460');
const array = (value) => (Array.isArray(value) ? value : []);
const safeId = (value) => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,100}$/.test(value);
const time = (value) => (Number.isFinite(value) && value > 0 ? value : Date.now());
const spaceIcon = (value) => (SPACE_ICONS.has(value) ? value : 'circle');
function spaceTheme(value, base = DEFAULT_SPACE_THEME) {
  const next = { ...base };
  if (!value || typeof value !== 'object' || Array.isArray(value)) return next;
  if (/^#[\da-f]{6}$/i.test(value.secondaryColor || '')) next.secondaryColor = value.secondaryColor;
  for (const [key, minimum, maximum] of [
    ['gradient', 0, 100],
    ['vibrancy', 0, 100],
    ['grain', 0, 200],
    ['opacity', 0, 100],
    ['blur', 0, 32],
  ])
    if (Number.isFinite(value[key])) next[key] = Math.round(Math.max(minimum, Math.min(maximum, value[key])));
  return next;
}

function normalizeAddress(input, searchEngine = 'duckduckgo') {
  const value = str(input, 8192);
  if (!value || value === 'zacro://newtab' || value === 'about:blank') return 'zacro://newtab';
  if (/[\u0000-\u001f\u007f]/.test(value)) throw new Error('This address contains invalid characters.');
  // Host:port is not a URL scheme. Reject every other explicit non-web scheme.
  const hostPort = /^(?:localhost|[\w.-]+|\[[\da-f:]+\]):\d+(?:[/?#]|$)/i.test(value);
  if (!hostPort && /^[a-z][a-z\d+.-]*:/i.test(value)) {
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      throw new Error('This address is not valid.');
    }
    if (!['http:', 'https:'].includes(parsed.protocol))
      throw new Error('Only HTTP and HTTPS web addresses are supported.');
    if (parsed.username || parsed.password)
      throw new Error('Addresses containing embedded passwords are not allowed.');
    return parsed.href;
  }
  if (
    !/\s/.test(value) &&
    (hostPort ||
      /^(localhost|\[[\da-f:]+\])(?:[/?#]|$)/i.test(value) ||
      /^[^/]+\.[^/]+(?:[/?#]|$)/.test(value))
  ) {
    const local = /^(localhost|127\.\d+\.\d+\.\d+|\[::1\])(?=[:/?#]|$)/i.test(value);
    try {
      const parsed = new URL(`${local ? 'http' : 'https'}://${value}`);
      if (parsed.username || parsed.password) throw new Error('credentials');
      return parsed.href;
    } catch {
      throw new Error('This address is not valid.');
    }
  }
  return (SEARCH[searchEngine] || SEARCH.duckduckgo) + encodeURIComponent(value);
}

function webUrl(value) {
  if (typeof value !== 'string' || value.length > 8192) return null;
  try {
    const parsed = new URL(value);
    return ['http:', 'https:'].includes(parsed.protocol) && !parsed.username && !parsed.password
      ? parsed.href
      : null;
  } catch {
    return null;
  }
}
function extensionUrl(value) {
  try {
    const url = new URL(value);
    return typeof value === 'string' &&
      value.length <= 8192 &&
      url.protocol === 'chrome-extension:' &&
      /^[a-p]{32}$/.test(url.hostname) &&
      !url.username &&
      !url.password &&
      !url.port &&
      !url.pathname.startsWith('/zacro-compat-')
      ? url.href
      : null;
  } catch {
    return null;
  }
}

function createInitialState() {
  return {
    version: 1,
    profiles: [{ id: 'default', name: 'Personal', private: false, archiveAfterHours: null }],
    spaces: [
      {
        id: 'home',
        profileId: 'default',
        name: 'Personal',
        color: '#9d4460',
        icon: 'circle',
        theme: spaceTheme(),
      },
    ],
    activeSpaceId: 'home',
    activeTabId: null,
    tabs: [],
    splitGroups: [],
    folders: [],
    history: [],
    bookmarks: [],
    archive: [],
    downloads: [],
    extensions: [],
    permissions: [],
    settings: {
      theme: 'system',
      searchEngine: 'duckduckgo',
      archiveAfterHours: DEFAULT_ARCHIVE_HOURS,
      sidebarWidth: 224,
      panelWidth: 336,
      siteSearches: normalizeSiteSearches(),
      restoreSession: true,
      onboardingCompleted: false,
      openSourcesLimit: 3,
      aiProvider: 'codex',
      aiModel: '',
      sharePageContext: false,
      shortcutOverrides: {},
      pinnedSleepMinutes: 20,
      pageGutter: 8,
      pageRadius: 12,
      motionScale: 1,
      tabDensity: 'comfortable',
    },
    windowBounds: { width: 1440, height: 940 },
  };
}

function validateSettings(values, base = createInitialState().settings) {
  const next = { ...base };
  if (!values || typeof values !== 'object' || Array.isArray(values)) return next;
  if (THEMES.has(values.theme)) next.theme = values.theme;
  if (Object.hasOwn(SEARCH, values.searchEngine)) next.searchEngine = values.searchEngine;
  if (validArchiveHours(values.archiveAfterHours)) next.archiveAfterHours = values.archiveAfterHours;
  if (Number.isFinite(values.sidebarWidth))
    next.sidebarWidth = Math.round(Math.min(380, Math.max(200, values.sidebarWidth)));
  if (Number.isFinite(values.panelWidth))
    next.panelWidth = Math.round(Math.min(560, Math.max(260, values.panelWidth)));
  if (Object.hasOwn(values, 'siteSearches')) next.siteSearches = normalizeSiteSearches(values.siteSearches);
  if (Number.isInteger(values.openSourcesLimit))
    next.openSourcesLimit = Math.min(10, Math.max(1, values.openSourcesLimit));
  for (const key of ['restoreSession', 'sharePageContext', 'onboardingCompleted'])
    if (typeof values[key] === 'boolean') next[key] = values[key];
  if (['codex', 'claude-code', 'openai', 'anthropic', 'compatible', 'openrouter'].includes(values.aiProvider))
    next.aiProvider = values.aiProvider;
  if (
    typeof values.aiModel === 'string' &&
    (!values.aiModel || /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,159}$/.test(values.aiModel))
  )
    next.aiModel = values.aiModel;
  if (Object.hasOwn(values, 'shortcutOverrides'))
    next.shortcutOverrides = sanitizeOverrides(values.shortcutOverrides);
  if ([0, 5, 10, 20, 30, 60, 120].includes(values.pinnedSleepMinutes))
    next.pinnedSleepMinutes = values.pinnedSleepMinutes;
  for (const [key, minimum, maximum] of [
    ['pageGutter', 4, 20],
    ['pageRadius', 0, 20],
  ])
    if (Number.isFinite(values[key]))
      next[key] = Math.round(Math.max(minimum, Math.min(maximum, values[key])));
  if (Number.isFinite(values.motionScale))
    next.motionScale = Math.round(Math.max(0.7, Math.min(1.4, values.motionScale)) * 100) / 100;
  if (['compact', 'comfortable'].includes(values.tabDensity)) next.tabDensity = values.tabDensity;
  return next;
}

function hydrate(raw) {
  if (!raw || raw.version !== 1 || !Array.isArray(raw.profiles) || !Array.isArray(raw.spaces))
    throw new Error('Unsupported or damaged browser data.');
  const result = createInitialState();
  const seen = new Set();
  const unique = (record) => record && safeId(record.id) && !seen.has(record.id) && seen.add(record.id);
  result.profiles = raw.profiles
    .filter((p) => unique(p) && !p.private)
    .slice(0, 100)
    .map((p) => ({
      id: p.id,
      name: str(p.name) || 'Profile',
      private: false,
      archiveAfterHours: validArchiveHours(p.archiveAfterHours) ? p.archiveAfterHours : null,
    }));
  if (!result.profiles.length) throw new Error('No valid profile found.');
  const profiles = new Set(result.profiles.map((p) => p.id));
  result.spaces = raw.spaces
    .filter((s) => unique(s) && profiles.has(s.profileId))
    .slice(0, 500)
    .map((s) => ({
      id: s.id,
      profileId: s.profileId,
      name: str(s.name) || 'Space',
      color: color(s.color),
      icon: spaceIcon(s.icon),
      theme: spaceTheme(s.theme),
      lastActiveTabId: str(s.lastActiveTabId, 100),
    }));
  for (const p of result.profiles)
    if (!result.spaces.some((s) => s.profileId === p.id))
      result.spaces.push({
        id: id('space'),
        profileId: p.id,
        name: p.name,
        color: '#9d4460',
        icon: 'circle',
        theme: spaceTheme(),
      });
  const spaces = new Map(result.spaces.map((s) => [s.id, s]));
  result.folders = array(raw.folders)
    .filter((f) => unique(f) && spaces.has(f.spaceId))
    .slice(0, 1000)
    .map((f) => ({ id: f.id, spaceId: f.spaceId, name: str(f.name) || 'Folder' }));
  const folders = new Map(result.folders.map((f) => [f.id, f]));
  const cleanTab = (t) => {
    const folderId = folders.get(t.folderId)?.spaceId === t.spaceId ? t.folderId : null;
    const favorite = Boolean(t.pinned && t.favorite !== false && !folderId);
    const pinned = Boolean(t.pinned || folderId);
    return {
      id: t.id,
      spaceId: t.spaceId,
      profileId: spaces.get(t.spaceId).profileId,
      title: str(t.customTitle, 500) || str(t.title, 500) || 'New tab',
      ...(str(t.customTitle, 500) ? { customTitle: str(t.customTitle, 500) } : {}),
      url: webUrl(t.url) || extensionUrl(t.url) || 'zacro://newtab',
      ...(t.homePage === true && !webUrl(t.url) && !extensionUrl(t.url) ? { homePage: true } : {}),
      pinned,
      // Before favorites and Space pins were distinct, every pin was an icon tile.
      // Preserve that placement on upgrade rather than silently moving saved tabs.
      favorite,
      ...(pinned
        ? {
            pinnedUrl:
              webUrl(t.pinnedUrl) ||
              extensionUrl(t.pinnedUrl) ||
              webUrl(t.url) ||
              extensionUrl(t.url) ||
              'zacro://newtab',
            pinnedTitle: str(t.pinnedTitle, 500) || str(t.title, 500) || 'New tab',
          }
        : {}),
      ...(pinned && t.closed === true ? { closed: true } : {}),
      ...(!(pinned && t.closed) && webUrl(t.savedPeek?.url)
        ? { savedPeek: { url: webUrl(t.savedPeek.url), title: str(t.savedPeek.title, 500) } }
        : {}),
      ...(!(pinned && t.closed) && cleanNavigationHistory(t.navigationHistory, t.url)
        ? { navigationHistory: cleanNavigationHistory(t.navigationHistory, t.url) }
        : {}),
      folderId: favorite ? null : folderId,
      createdAt: time(t.createdAt),
      lastActiveAt: time(t.lastActiveAt),
    };
  };
  result.tabs = array(raw.tabs)
    .filter((t) => unique(t) && spaces.has(t.spaceId))
    .slice(0, MAX_TABS)
    .map(cleanTab);
  result.splitGroups = cleanSplitGroups(raw.splitGroups, result.tabs, result.spaces);
  result.archive = array(raw.archive)
    .filter((t) => unique(t) && spaces.has(t.spaceId))
    .slice(0, MAX_ARCHIVE)
    .map((t) => {
      const { savedPeek, ...tab } = cleanTab(t);
      return { ...tab, archivedAt: time(t.archivedAt) };
    });
  result.history = array(raw.history)
    .filter((h) => unique(h) && profiles.has(h.profileId) && webUrl(h.url))
    .slice(0, MAX_HISTORY)
    .map((h) => ({
      id: h.id,
      profileId: h.profileId,
      url: webUrl(h.url),
      title: str(h.title, 500),
      visitedAt: time(h.visitedAt),
    }));
  result.bookmarks = array(raw.bookmarks)
    .filter((b) => unique(b) && profiles.has(b.profileId) && webUrl(b.url))
    .slice(0, 20000)
    .map((b) => ({
      id: b.id,
      profileId: b.profileId,
      url: webUrl(b.url),
      title: str(b.title, 500),
      createdAt: time(b.createdAt),
    }));
  result.permissions = array(raw.permissions)
    .filter(
      (p) =>
        p &&
        profiles.has(p.profileId) &&
        webUrl(p.origin) &&
        typeof p.permission === 'string' &&
        typeof p.allowed === 'boolean',
    )
    .slice(0, 2000)
    .map((p) => ({
      profileId: p.profileId,
      origin: new URL(p.origin).origin,
      permission: str(p.permission, 80),
      allowed: p.allowed,
    }));
  // Downloads and extension paths originate in the trusted main process, never portable imports.
  result.downloads = array(raw.downloads)
    .filter((d) => d && safeId(d.id) && profiles.has(d.profileId))
    .slice(0, 1000)
    .map((d) => ({
      ...d,
      state: ['completed', 'cancelled', 'interrupted'].includes(d.state) ? d.state : 'interrupted',
    }));
  result.extensions = array(raw.extensions)
    .filter((e) => e && safeId(e.id) && profiles.has(e.profileId) && typeof e.path === 'string')
    .slice(0, 200);
  result.settings = validateSettings(raw.settings);
  normalizeDefaultArchive(result);
  result.activeSpaceId = spaces.has(raw.activeSpaceId) ? raw.activeSpaceId : result.spaces[0].id;
  for (const space of result.spaces)
    if (
      !result.tabs.some(
        (tab) =>
          tab.id === space.lastActiveTabId &&
          (tab.spaceId === space.id || (tab.favorite && tab.profileId === space.profileId)),
      )
    )
      delete space.lastActiveTabId;
  const selectedFavorite = result.tabs.find(
    (tab) =>
      tab.id === raw.activeTabId &&
      tab.favorite &&
      tab.profileId === spaces.get(result.activeSpaceId).profileId,
  );
  if (selectedFavorite) selectedFavorite.spaceId = result.activeSpaceId;
  result.activeTabId = result.tabs.some(
    (t) => t.id === raw.activeTabId && t.spaceId === result.activeSpaceId && !t.closed,
  )
    ? raw.activeTabId
    : result.tabs.find((t) => t.spaceId === result.activeSpaceId && !t.closed)?.id || null;
  if (raw.windowBounds && typeof raw.windowBounds === 'object') {
    const { width, height, x, y } = raw.windowBounds;
    result.windowBounds = {
      width: Math.min(7680, Math.max(560, Number(width) || 1440)),
      height: Math.min(4320, Math.max(420, Number(height) || 940)),
      maximized: raw.windowBounds.maximized === true,
      sizeKind: raw.windowBounds.sizeKind === 'window' ? 'window' : 'content',
    };
    if (Number.isFinite(x)) result.windowBounds.x = Math.round(x);
    if (Number.isFinite(y)) result.windowBounds.y = Math.round(y);
  }
  return result;
}

class BrowserStore extends EventEmitter {
  constructor(directory) {
    super();
    this.directory = directory;
    this.file = directory ? path.join(directory, 'browser-state.json') : null;
    this.recoveryWarning = null;
    this.recoveryPurgePending = false;
    this.state = createInitialState();
    if (this.file) {
      fs.mkdirSync(directory, { recursive: true });
      if (fs.existsSync(this.file)) {
        try {
          this.state = this.readFile(this.file);
        } catch (error) {
          const quarantine = `${this.file}.damaged-${Date.now()}`;
          try {
            fs.copyFileSync(this.file, quarantine);
          } catch {
            /* best effort preservation */
          }
          try {
            this.state = this.readFile(`${this.file}.bak`);
            this.recoveryWarning = 'Recovered your session from its last backup.';
          } catch {
            this.recoveryWarning = 'Your saved session could not be read. A copy was preserved for recovery.';
          }
        }
      }
    }
    if (!this.state.settings.restoreSession) {
      const grouped = new Set(this.state.splitGroups.flatMap((group) => group.tabIds));
      this.state.archive = [
        ...this.state.tabs
          .filter((t) => !t.pinned && !t.savedPeek && !grouped.has(t.id) && t.url !== 'zacro://newtab')
          .map((t) => ({ ...t, archivedAt: Date.now() })),
        ...this.state.archive,
      ].slice(0, MAX_ARCHIVE);
      this.state.tabs = this.state.tabs.filter((t) => t.pinned || t.savedPeek || grouped.has(t.id));
      this.state.activeTabId = null;
    }
    // Favorites are destinations, not a request to start every saved renderer.
    // Even a favorite selected at shutdown stays dormant until selected again.
    if (
      this.state.tabs.find((tab) => tab.id === this.state.activeTabId)?.pinned &&
      !this.state.tabs.find((tab) => tab.id === this.state.activeTabId)?.savedPeek &&
      !this.state.splitGroups.some((group) => group.tabIds.includes(this.state.activeTabId))
    )
      this.state.activeTabId =
        this.state.tabs.find((tab) => tab.spaceId === this.state.activeSpaceId && !tab.pinned)?.id || null;
  }
  readFile(file) {
    if (fs.statSync(file).size > 32 * 1024 * 1024) throw new Error('Browser data exceeds its safety limit.');
    return hydrate(JSON.parse(fs.readFileSync(file, 'utf8')));
  }
  snapshot() {
    return clone(this.state);
  }
  changed() {
    this.emit('change', this.state);
    if (this.file) {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        try {
          this.save();
        } catch (error) {
          this.emit('persistence-error', error);
        }
      }, 250);
      this.timer.unref?.();
    }
  }
  persistedState() {
    const s = clone(this.state);
    const allowed = new Set(s.profiles.filter((p) => !p.private).map((p) => p.id));
    s.profiles = s.profiles.filter((p) => allowed.has(p.id));
    s.spaces = s.spaces.filter((p) => allowed.has(p.profileId));
    const spaces = new Set(s.spaces.map((p) => p.id));
    s.folders = s.folders.filter((f) => spaces.has(f.spaceId));
    for (const key of ['tabs', 'history', 'archive', 'bookmarks', 'downloads', 'extensions', 'permissions'])
      s[key] = s[key].filter((r) => allowed.has(r.profileId));
    s.splitGroups = cleanSplitGroups(s.splitGroups, s.tabs, s.spaces);
    if (!spaces.has(s.activeSpaceId)) s.activeSpaceId = s.spaces[0]?.id;
    if (!s.tabs.some((t) => t.id === s.activeTabId && t.spaceId === s.activeSpaceId && !t.closed))
      s.activeTabId = s.tabs.find((t) => t.spaceId === s.activeSpaceId && !t.pinned)?.id || null;
    return s;
  }
  save() {
    clearTimeout(this.timer);
    if (!this.file) return;
    const tmp = `${this.file}.tmp`;
    const bytes = JSON.stringify(this.persistedState());
    const fd = fs.openSync(tmp, 'w', 0o600);
    try {
      fs.writeFileSync(fd, bytes);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    if (fs.existsSync(this.file) && !this.recoveryWarning && !this.recoveryPurgePending)
      fs.copyFileSync(this.file, `${this.file}.bak`);
    fs.renameSync(tmp, this.file);
    if (this.recoveryPurgePending) {
      const backupTemporary = `${this.file}.bak.tmp`;
      const backupFD = fs.openSync(backupTemporary, 'w', 0o600);
      try {
        fs.writeFileSync(backupFD, bytes);
        fs.fsyncSync(backupFD);
      } finally {
        fs.closeSync(backupFD);
      }
      fs.renameSync(backupTemporary, `${this.file}.bak`);
      const directory = path.resolve(this.directory);
      for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        if (
          !/^browser-state\.json\.damaged-\d+$/.test(entry.name) ||
          (!entry.isFile() && !entry.isSymbolicLink())
        )
          continue;
        const candidate = path.resolve(directory, entry.name);
        if (path.dirname(candidate) !== directory) throw new Error('Invalid recovery-file location.');
        // Unlink only a reserved recovery file (or its link), never a directory
        // or anything reached through a link. Corrupt JSON cannot be redacted
        // reliably, so explicit deletion discards these older recovery copies.
        fs.unlinkSync(candidate);
      }
      this.recoveryPurgePending = false;
    }
    this.recoveryWarning = null;
  }
  flush() {
    this.save();
  }
  require(list, recordId, label) {
    const record = this.state[list].find((r) => r.id === recordId);
    if (!record) throw new Error(`${label} was not found.`);
    return record;
  }
  activeSpace() {
    return this.require('spaces', this.state.activeSpaceId, 'Space');
  }
  private(profileId) {
    return this.require('profiles', profileId, 'Profile').private;
  }
  activateSpace(space) {
    this.state.activeSpaceId = space.id;
    const remembered = this.state.tabs.find(
      (tab) =>
        tab.id === space.lastActiveTabId &&
        !tab.closed &&
        (tab.spaceId === space.id || (tab.favorite && tab.profileId === space.profileId)),
    );
    // A Favorite has one live document per profile. Its spaceId records where it
    // was last used, rather than duplicating cookies, callbacks or tab renderers.
    if (remembered?.favorite) remembered.spaceId = space.id;
    this.state.activeTabId =
      remembered?.id ||
      this.state.tabs.find((tab) => tab.spaceId === space.id && !tab.favorite && !tab.closed)?.id ||
      null;
    const viewed = this.state.tabs.find((tab) => tab.id === this.state.activeTabId);
    if (viewed) viewed.lastActiveAt = Date.now();
  }
  activateTab(tab, activate = true) {
    const current = this.activeSpace();
    if (tab.favorite && tab.profileId === current.profileId) tab.spaceId = current.id;
    if (activate) {
      this.state.activeTabId = tab.id;
      this.state.activeSpaceId = tab.spaceId;
      this.require('spaces', tab.spaceId, 'Space').lastActiveTabId = tab.id;
    }
    tab.lastActiveAt = Date.now();
    delete tab.closed;
  }
  setPinned(tab, pinned, favorite = false) {
    if (pinned) {
      if (!tab.pinned) tab.pinnedUrl = tab.url;
      tab.pinnedUrl ||= tab.url;
      tab.pinnedTitle ||= tab.title;
      tab.pinned = true;
      tab.favorite = favorite;
      if (favorite) tab.folderId = null;
    } else {
      tab.pinned = false;
      tab.favorite = false;
      tab.folderId = null;
      delete tab.pinnedUrl;
      delete tab.pinnedTitle;
    }
  }
  closeTab(tab, archive = true) {
    delete tab.savedPeek;
    const position = this.state.tabs.indexOf(tab);
    if (tab.pinned) {
      tab.closed = true;
      delete tab.navigationHistory;
      tab.url = tab.pinnedUrl || tab.url;
      if (this.state.activeTabId === tab.id)
        this.state.activeTabId =
          this.state.tabs.slice(position + 1).find((item) => item.spaceId === tab.spaceId && !item.pinned)
            ?.id ||
          this.state.tabs.filter((item) => item.spaceId === tab.spaceId && !item.pinned).at(-1)?.id ||
          null;
      if (this.state.activeSpaceId === tab.spaceId)
        this.require('spaces', tab.spaceId, 'Space').lastActiveTabId = this.state.activeTabId;
      return;
    }
    if (archive && tab.url !== 'zacro://newtab' && !this.private(tab.profileId))
      this.state.archive = [
        { ...tab, archivedAt: Date.now() },
        ...this.state.archive.filter((a) => a.id !== tab.id),
      ].slice(0, MAX_ARCHIVE);
    this.state.tabs.splice(position, 1);
    if (this.state.activeTabId === tab.id) {
      const same = this.state.tabs.filter((t) => t.spaceId === tab.spaceId && !t.pinned);
      const candidate = this.state.tabs.slice(position).find((t) => t.spaceId === tab.spaceId && !t.pinned);
      this.state.activeTabId = candidate?.id || same.at(-1)?.id || null;
      this.require('spaces', tab.spaceId, 'Space').lastActiveTabId = this.state.activeTabId;
    }
  }
  dispatch(action, payload = {}) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload))
      throw new Error('Invalid action payload.');
    const p = payload,
      s = this.state,
      now = Date.now();
    const previousActiveId = s.activeTabId;
    let result = null;
    switch (action) {
      case 'peek:set': {
        const tab = this.require('tabs', p.sourceTabId, 'Tab');
        if (p.url == null) delete tab.savedPeek;
        else {
          const url = webUrl(p.url);
          if (!url || tab.closed) throw new Error('Choose an open tab and a web link to preview.');
          tab.savedPeek = { url, title: str(p.title, 500) };
        }
        result = tab.savedPeek || null;
        break;
      }
      case 'split:create': {
        const first = this.require('tabs', p.firstId || s.activeTabId, 'Tab');
        const second = this.require('tabs', p.secondId, 'Tab');
        const space = this.require('spaces', p.spaceId || s.activeSpaceId, 'Space');
        if (
          first.id === second.id ||
          [first, second].some(
            (tab) =>
              tab.closed ||
              tab.url === 'zacro://newtab' ||
              tab.profileId !== space.profileId ||
              (!tab.favorite && tab.spaceId !== space.id),
          )
        )
          throw new Error('Choose two open web pages in the same Space.');
        const existing = s.splitGroups.find(
          (group) => group.tabIds.includes(first.id) || group.tabIds.includes(second.id),
        );
        if (existing) {
          if (
            existing.spaceId === space.id &&
            existing.tabIds.includes(first.id) &&
            existing.tabIds.includes(second.id)
          ) {
            result = existing;
            break;
          }
          throw new Error('Unsplit these tabs before adding them to another split view.');
        }
        result = { id: id('split'), spaceId: space.id, tabIds: [first.id, second.id] };
        s.splitGroups.push(result);
        break;
      }
      case 'split:remove': {
        const group = s.splitGroups.find(
          (item) => item.id === p.id || item.tabIds.includes(p.tabId || s.activeTabId),
        );
        if (group) s.splitGroups = s.splitGroups.filter((item) => item !== group);
        break;
      }
      case 'tab:create': {
        if (s.tabs.length >= MAX_TABS) throw new Error('Close some tabs before opening more.');
        const space = this.require('spaces', p.spaceId || s.activeSpaceId, 'Space');
        const url = normalizeAddress(p.url, s.settings.searchEngine);
        const tab = {
          id: id('tab'),
          spaceId: space.id,
          profileId: space.profileId,
          url,
          title: url === 'zacro://newtab' ? 'New tab' : new URL(url).hostname,
          ...(p.homePage === true && (!p.url || p.url === 'zacro://newtab') ? { homePage: true } : {}),
          pinned: false,
          favorite: false,
          folderId: null,
          createdAt: now,
          lastActiveAt: now,
        };
        s.tabs.push(tab);
        if (p.active !== false) {
          s.activeSpaceId = space.id;
          s.activeTabId = tab.id;
          space.lastActiveTabId = tab.id;
        }
        result = tab;
        break;
      }
      case 'tab:activate':
      case 'tab:wake': {
        const tab = this.require('tabs', p.id, 'Tab');
        this.activateTab(tab, action === 'tab:activate');
        result = tab;
        break;
      }
      case 'tab:extension-page': {
        const tab = this.require('tabs', p.id, 'Tab');
        const url = extensionUrl(p.url);
        if (!url) throw new Error('Invalid extension page.');
        tab.url = url;
        delete tab.homePage;
        if (p.title !== undefined && !tab.customTitle) tab.title = str(p.title, 500) || tab.url;
        result = tab;
        break;
      }
      case 'tab:update': {
        const tab = this.require('tabs', p.id, 'Tab');
        if (p.url !== undefined) tab.url = normalizeAddress(p.url, s.settings.searchEngine);
        if (tab.url !== 'zacro://newtab') delete tab.homePage;
        if (p.title !== undefined && !tab.customTitle) tab.title = str(p.title, 500) || tab.url;
        result = tab;
        break;
      }
      case 'tab:rename': {
        const tab = this.require('tabs', p.id, 'Tab');
        const name = str(p.title, 500);
        if (!name) throw new Error('Give your tab a name.');
        tab.customTitle = name;
        tab.title = name;
        result = tab;
        break;
      }
      case 'tab:close':
        this.closeTab(this.require('tabs', p.id || s.activeTabId, 'Tab'));
        break;
      case 'tab:pin': {
        const tab = this.require('tabs', p.id || s.activeTabId, 'Tab');
        if (tab.favorite && tab.profileId === this.activeSpace().profileId) tab.spaceId = s.activeSpaceId;
        this.setPinned(tab, !tab.pinned);
        if (!tab.pinned && tab.closed) {
          delete tab.closed;
          this.closeTab(tab, false);
        }
        result = tab;
        break;
      }
      case 'tab:favorite': {
        const tab = this.require('tabs', p.id || s.activeTabId, 'Tab');
        if (tab.profileId === this.activeSpace().profileId) tab.spaceId = s.activeSpaceId;
        this.setPinned(tab, true, p.favorite !== false);
        result = tab;
        break;
      }
      case 'tab:reset-pin': {
        const tab = this.require('tabs', p.id || s.activeTabId, 'Tab');
        if (!tab.pinned) throw new Error('Only a Pinned Tab or Favorite has a saved destination.');
        tab.url = tab.pinnedUrl || tab.url;
        result = tab;
        break;
      }
      case 'tab:replace-pin': {
        const tab = this.require('tabs', p.id || s.activeTabId, 'Tab');
        if (!tab.pinned) throw new Error('Only a Pinned Tab or Favorite has a saved destination.');
        tab.pinnedUrl = tab.url;
        tab.pinnedTitle = tab.title;
        result = tab;
        break;
      }
      case 'tab:move': {
        const tab = this.require('tabs', p.id, 'Tab');
        const space = this.require('spaces', p.spaceId || tab.spaceId, 'Space');
        if (space.profileId !== tab.profileId)
          throw new Error(
            'Tabs cannot move between profiles. Open the address in the other profile instead.',
          );
        if (p.folderId) {
          const folder = this.require('folders', p.folderId, 'Folder');
          if (folder.spaceId !== space.id) throw new Error('That folder belongs to another Space.');
        }
        const oldSpace = tab.spaceId;
        const group = s.splitGroups.find((item) => item.tabIds.includes(tab.id));
        const movingGroup = group && p.spaceId && group.spaceId !== space.id;
        if (movingGroup) {
          group.spaceId = space.id;
          for (const member of s.tabs.filter((item) => group.tabIds.includes(item.id))) {
            member.spaceId = space.id;
            member.folderId = null;
          }
        }
        tab.spaceId = space.id;
        if (p.folderId !== undefined || oldSpace !== space.id) tab.folderId = p.folderId || null;
        const favorite =
          typeof p.favorite === 'boolean'
            ? p.favorite
            : p.folderId || p.pinned === false || (p.spaceId && oldSpace !== space.id)
              ? false
              : tab.favorite;
        const pinned =
          favorite || (typeof p.pinned === 'boolean' ? p.pinned : p.folderId ? true : Boolean(tab.pinned));
        this.setPinned(tab, pinned, favorite);
        if (favorite) tab.folderId = null;
        if (!tab.pinned) delete tab.closed;
        if (Number.isInteger(p.index)) {
          s.tabs.splice(s.tabs.indexOf(tab), 1);
          s.tabs.splice(Math.min(s.tabs.length, Math.max(0, p.index)), 0, tab);
        }
        if (s.activeTabId === tab.id || (movingGroup && group.tabIds.includes(s.activeTabId))) {
          s.activeSpaceId = tab.spaceId;
          space.lastActiveTabId = s.activeTabId;
        }
        result = tab;
        break;
      }
      case 'tab:restore': {
        const match = p.id
          ? s.archive.find((t) => t.id === p.id)
          : s.archive.find((t) => t.spaceId === s.activeSpaceId);
        if (!match) throw new Error('There are no archived tabs to restore in this Space.');
        if (s.tabs.length >= MAX_TABS) throw new Error('Close some tabs before restoring more.');
        const tab = { ...match, lastActiveAt: now };
        delete tab.archivedAt;
        delete tab.closed;
        if (s.tabs.some((t) => t.id === tab.id)) tab.id = id('tab');
        if (!s.folders.some((f) => f.id === tab.folderId && f.spaceId === tab.spaceId)) tab.folderId = null;
        s.archive = s.archive.filter((t) => t !== match);
        s.tabs.push(tab);
        s.activeSpaceId = tab.spaceId;
        s.activeTabId = tab.id;
        result = tab;
        break;
      }
      case 'tab:archive-stale': {
        const excluded = new Set(Array.isArray(p.excludeIds) ? p.excludeIds : []);
        const included = Array.isArray(p.ids) ? new Set(p.ids) : null;
        const stale = s.tabs.filter(
          (tab) =>
            (!included || included.has(tab.id)) &&
            !excluded.has(tab.id) &&
            archiveCandidate(s, tab, Number.isFinite(p.now) ? p.now : now),
        );
        for (const tab of stale) this.closeTab(tab);
        result = stale.length;
        break;
      }
      case 'space:create': {
        if (s.spaces.length >= 500) throw new Error('Space limit reached.');
        const profile = this.require('profiles', p.profileId || this.activeSpace().profileId, 'Profile');
        if (!str(p.name)) throw new Error('Give your Space a name.');
        const space = {
          id: id('space'),
          profileId: profile.id,
          name: str(p.name),
          color: color(p.color),
          icon: spaceIcon(p.icon),
          theme: spaceTheme(p.theme),
        };
        s.spaces.push(space);
        this.activateSpace(space);
        result = space;
        break;
      }
      case 'space:update': {
        const space = this.require('spaces', p.id, 'Space');
        if (p.name !== undefined) {
          if (!str(p.name)) throw new Error('Give your Space a name.');
          space.name = str(p.name);
        }
        if (p.color !== undefined) space.color = color(p.color);
        if (p.icon !== undefined) space.icon = spaceIcon(p.icon);
        if (p.theme !== undefined) space.theme = spaceTheme(p.theme, space.theme || DEFAULT_SPACE_THEME);
        result = space;
        break;
      }
      case 'space:activate':
        this.activateSpace(this.require('spaces', p.id, 'Space'));
        break;
      case 'space:delete': {
        const space = this.require('spaces', p.id, 'Space');
        const others = s.spaces.filter((r) => r.profileId === space.profileId && r.id !== space.id);
        if (!others.length) throw new Error('Keep at least one Space in each profile.');
        const destination = others[0];
        for (const group of s.splitGroups) if (group.spaceId === space.id) group.spaceId = destination.id;
        for (const tab of [...s.tabs, ...s.archive].filter((t) => t.spaceId === space.id)) {
          tab.spaceId = destination.id;
          tab.folderId = null;
        }
        s.folders = s.folders.filter((f) => f.spaceId !== space.id);
        s.spaces = s.spaces.filter((r) => r !== space);
        if (s.activeSpaceId === space.id) this.activateSpace(destination);
        break;
      }
      case 'profile:create': {
        if (s.profiles.length >= 100) throw new Error('Profile limit reached.');
        if (!str(p.name)) throw new Error('Give your profile a name.');
        const profile = {
          id: id('profile'),
          name: str(p.name),
          private: p.private === true,
          archiveAfterHours: validArchiveHours(p.archiveAfterHours) ? p.archiveAfterHours : null,
        };
        const space = {
          id: id('space'),
          profileId: profile.id,
          name: profile.private ? 'Private' : profile.name,
          color: profile.private ? '#69519c' : color(p.color),
          icon: profile.private ? 'moon' : 'circle',
          theme: spaceTheme(),
        };
        s.profiles.push(profile);
        s.spaces.push(space);
        this.activateSpace(space);
        result = profile;
        break;
      }
      case 'profile:update': {
        const profile = this.require('profiles', p.id, 'Profile');
        const value = p.values?.archiveAfterHours;
        if (value !== null && !validArchiveHours(value)) throw new Error('Choose a valid archive cadence.');
        if (profile === defaultArchiveProfile(s)) {
          if (value !== null) s.settings.archiveAfterHours = value;
          profile.archiveAfterHours = null;
        } else profile.archiveAfterHours = value;
        result = profile;
        break;
      }
      case 'profile:delete': {
        const profile = this.require('profiles', p.id, 'Profile');
        if (!profile.private && s.profiles.filter((r) => !r.private).length <= 1)
          throw new Error('Keep at least one regular profile.');
        const removedSpaces = new Set(
          s.spaces.filter((sp) => sp.profileId === profile.id).map((sp) => sp.id),
        );
        s.profiles = s.profiles.filter((r) => r !== profile);
        s.spaces = s.spaces.filter((r) => !removedSpaces.has(r.id));
        s.folders = s.folders.filter((r) => !removedSpaces.has(r.spaceId));
        for (const key of [
          'tabs',
          'archive',
          'history',
          'bookmarks',
          'downloads',
          'extensions',
          'permissions',
        ])
          s[key] = s[key].filter((r) => r.profileId !== profile.id);
        if (removedSpaces.has(s.activeSpaceId)) this.activateSpace(s.spaces[0]);
        normalizeDefaultArchive(s);
        break;
      }
      case 'folder:create': {
        if (!str(p.name)) throw new Error('Give your folder a name.');
        if (s.folders.length >= 1000) throw new Error('Folder limit reached.');
        const space = this.require('spaces', p.spaceId || s.activeSpaceId, 'Space');
        const folder = { id: id('folder'), spaceId: space.id, name: str(p.name) };
        s.folders.push(folder);
        result = folder;
        break;
      }
      case 'folder:update': {
        const folder = this.require('folders', p.id, 'Folder');
        if (!str(p.name)) throw new Error('Give your folder a name.');
        folder.name = str(p.name);
        result = folder;
        break;
      }
      case 'folder:delete': {
        this.require('folders', p.id, 'Folder');
        s.folders = s.folders.filter((f) => f.id !== p.id);
        for (const tab of [...s.tabs, ...s.archive]) if (tab.folderId === p.id) tab.folderId = null;
        break;
      }
      case 'bookmark:toggle': {
        const tab = s.tabs.find((t) => t.id === s.activeTabId);
        const url = webUrl(p.url || tab?.url);
        if (!url) throw new Error('Only web pages can be bookmarked.');
        const profileId = p.profileId || this.activeSpace().profileId;
        this.require('profiles', profileId, 'Profile');
        const existing = s.bookmarks.find((b) => b.profileId === profileId && b.url === url);
        if (existing) s.bookmarks = s.bookmarks.filter((b) => b !== existing);
        else {
          result = {
            id: id('bookmark'),
            profileId,
            url,
            title: str(p.title || tab?.title || url, 500),
            createdAt: now,
          };
          s.bookmarks.unshift(result);
        }
        break;
      }
      case 'bookmark:delete':
        this.require('bookmarks', p.id, 'Bookmark');
        s.bookmarks = s.bookmarks.filter((b) => b.id !== p.id);
        break;
      case 'history:add': {
        const url = webUrl(p.url);
        const profileId = p.profileId || this.activeSpace().profileId;
        if (!url || this.private(profileId)) break;
        const recent = s.history.find((h) => h.profileId === profileId);
        if (recent?.url === url && now - recent.visitedAt < 60000) {
          recent.title = str(p.title, 500) || recent.title;
          recent.visitedAt = now;
        } else
          s.history.unshift({
            id: id('visit'),
            profileId,
            url,
            title: str(p.title, 500) || url,
            visitedAt: now,
          });
        s.history = s.history.slice(0, MAX_HISTORY);
        break;
      }
      case 'history:clear':
        for (const tab of [...s.tabs, ...s.archive])
          if (tab.profileId === (p.profileId || this.activeSpace().profileId)) delete tab.navigationHistory;
        s.history = s.history.filter((h) => h.profileId !== (p.profileId || this.activeSpace().profileId));
        break;
      case 'archive:clear':
        s.archive = s.archive.filter((h) => h.profileId !== (p.profileId || this.activeSpace().profileId));
        break;
      case 'settings:update':
        s.settings = validateSettings(p.values, s.settings);
        result = s.settings;
        break;
      case 'permission:set': {
        const profileId = p.profileId || this.activeSpace().profileId;
        this.require('profiles', profileId, 'Profile');
        if (!webUrl(p.origin) || !str(p.permission, 80) || typeof p.allowed !== 'boolean')
          throw new Error('Invalid site permission.');
        const origin = new URL(p.origin).origin;
        s.permissions = s.permissions.filter(
          (r) => !(r.profileId === profileId && r.origin === origin && r.permission === p.permission),
        );
        result = { profileId, origin, permission: str(p.permission, 80), allowed: p.allowed };
        s.permissions.push(result);
        break;
      }
      case 'permission:clear':
        s.permissions = s.permissions.filter(
          (r) => r.profileId !== (p.profileId || this.activeSpace().profileId),
        );
        break;
      default:
        throw new Error(`Unknown action: ${str(action, 80)}`);
    }
    s.splitGroups = cleanSplitGroups(s.splitGroups, s.tabs, s.spaces);
    const tabsById = new Map(s.tabs.map((tab) => [tab.id, tab]));
    for (const space of s.spaces) {
      const remembered = tabsById.get(space.lastActiveTabId);
      if (
        space.lastActiveTabId &&
        (!remembered ||
          (remembered.spaceId !== space.id &&
            !(remembered.favorite && remembered.profileId === space.profileId)))
      )
        delete space.lastActiveTabId;
    }
    // Time spent viewing a tab is activity too. Start its idle period on
    // departure, rather than immediately archiving a page read for hours.
    if (previousActiveId !== s.activeTabId) {
      for (const tab of s.tabs)
        if (tab.id === previousActiveId || tab.id === s.activeTabId) tab.lastActiveAt = now;
    }
    if (this.file && RECOVERY_PURGE_ACTIONS.has(action)) this.recoveryPurgePending = true;
    this.changed();
    // Do not report an explicit clear as successful while deleted records still
    // exist in an application-managed backup. On failure the flag remains set
    // for retry, and the caller receives the filesystem error.
    if (this.recoveryPurgePending) this.save();
    return result ? clone(result) : result;
  }
  exportData() {
    const s = this.persistedState();
    return {
      format: 'zacro-export',
      version: 1,
      exportedAt: new Date().toISOString(),
      profiles: s.profiles,
      spaces: s.spaces,
      tabs: s.tabs.map(({ navigationHistory, ...tab }) => tab),
      folders: s.folders,
      splitGroups: s.splitGroups,
      bookmarks: s.bookmarks,
      settings: s.settings,
    };
  }
  importData(raw) {
    if (!raw || raw.format !== 'zacro-export' || raw.version !== 1)
      throw new Error('Choose a Zacro JSON export or a browser bookmarks HTML file.');
    const data = hydrate({
      ...raw,
      tabs: array(raw.tabs).map((item) => {
        if (!item || typeof item !== 'object') return item;
        const { navigationHistory, ...tab } = item;
        return tab;
      }),
      history: [],
      downloads: [],
      extensions: [],
      permissions: [],
      archive: [],
    });
    if (
      this.state.tabs.length + data.tabs.length > MAX_TABS ||
      this.state.profiles.length + data.profiles.length > 100 ||
      this.state.spaces.length + data.spaces.length > 500
    )
      throw new Error('This import would exceed the browser’s collection limits.');
    const mappings = new Map();
    for (const key of ['profiles', 'spaces', 'folders', 'tabs', 'splitGroups', 'bookmarks'])
      for (const row of data[key]) mappings.set(row.id, id(key.slice(0, -1)));
    for (const key of ['profiles', 'spaces', 'folders', 'tabs', 'splitGroups', 'bookmarks']) {
      for (const row of data[key]) {
        const next = { ...row, id: mappings.get(row.id) };
        if (key === 'splitGroups') next.tabIds = row.tabIds.map((id) => mappings.get(id));
        for (const field of ['profileId', 'spaceId', 'folderId', 'lastActiveTabId'])
          if (next[field]) next[field] = mappings.get(next[field]) || null;
        if (key === 'profiles') {
          next.name = `${next.name} (imported)`;
          // Import keeps this browser's defaults, so capture each source
          // profile's effective cadence instead of inheriting a different one.
          next.archiveAfterHours = archiveHours(data, row.id);
        }
        this.state[key].push(next);
      }
    }
    this.changed();
    return { profiles: data.profiles.length, tabs: data.tabs.length, bookmarks: data.bookmarks.length };
  }
  importBookmarks(records, profileId = this.activeSpace().profileId) {
    this.require('profiles', profileId, 'Profile');
    if (
      !Array.isArray(records) ||
      records.length > 20000 ||
      records.length + this.state.bookmarks.length > 20000
    )
      throw new Error('Bookmark import is too large (maximum 20,000).');
    const seen = new Set(this.state.bookmarks.filter((b) => b.profileId === profileId).map((b) => b.url));
    let count = 0;
    for (const row of records) {
      const url = webUrl(row?.url);
      if (!url || seen.has(url)) continue;
      seen.add(url);
      this.state.bookmarks.push({
        id: id('bookmark'),
        profileId,
        url,
        title: str(row.title, 500) || url,
        createdAt: Date.now(),
      });
      count++;
    }
    this.changed();
    return { bookmarks: count };
  }
}
module.exports = {
  BrowserStore,
  createInitialState,
  normalizeAddress,
  webUrl,
  hydrate,
  validateSettings,
  SEARCH,
  SPACE_ICONS,
  DEFAULT_SPACE_THEME,
  spaceTheme,
};
