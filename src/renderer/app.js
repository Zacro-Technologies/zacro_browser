const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const esc = (value = '') =>
  String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const icons = {
  plus: 'M12 5v14M5 12h14',
  layers: 'm12 3 10 6-10 6L2 9zM2 13l10 6 10-6M2 17l10 6 10-6',
  volume: 'M4 9h4l5-5v16l-5-5H4zM16 8a6 6 0 0 1 0 8M19 5a10 10 0 0 1 0 14',
  muted: 'M4 9h4l5-5v16l-5-5H4zM17 9l5 6M22 9l-5 6',
  close: 'm6 6 12 12M18 6 6 18',
  back: 'm14 5-7 7 7 7',
  forward: 'm10 5 7 7-7 7',
  down: 'm7 10 5 5 5-5',
  up: 'm7 14 5-5 5 5',
  reload: 'M20 7v5h-5M4 17v-5h5M6.1 7a7 7 0 0 1 11.6-2L20 8M4 16l2.3 3A7 7 0 0 0 18 17',
  search: 'M21 21l-5-5M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  star: 'm12 3 2.8 5.7 6.3.9-4.6 4.5 1.1 6.3L12 17.4l-5.6 3 1.1-6.3L3 9.6l6.2-.9z',
  split: 'M3 4h18v16H3zM12 4v16',
  sparkle: 'm12 3 2.4 6.6L21 12l-6.6 2.4L12 21l-2.4-6.6L3 12l6.6-2.4zM20 2v4M18 4h4',
  globe: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M3 12h18M12 3c5 5 5 13 0 18-5-5-5-13 0-18',
  lock: 'M6 10h12v11H6zM8 10V6a4 4 0 0 1 8 0v4',
  unlock: 'M6 10h12v11H6zM8 10V6a4 4 0 0 1 7.4-2',
  more: 'M4 12h.01M12 12h.01M20 12h.01',
  history: 'M3 11a9 9 0 1 1 2.5 7M3 4v7h7M12 7v5l3 2',
  bookmark: 'M6 3h12v18l-6-4-6 4z',
  download: 'M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5',
  settings: 'm9 3-1 3-3 1-2 4 2 3 1 4 3 1 3 2 3-2 3-1 1-4 2-3-2-4-3-1-1-3zM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  archive: 'M3 4h18v4H3zM5 8v12h14V8M9 12h6',
  folder: 'M3 5h7l2 3h9v12H3z',
  folderPlus: 'M3 5h7l2 3h9v12H3zM12 11v6M9 14h6',
  pin: 'm16 3 5 5-5 1-3 5 1 3-2 2-7-7 2-2 3 1 5-3zM5 19l-2 2',
  external: 'M14 3h7v7M21 3 10 14M10 3H3v18h18v-7',
  user: 'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0M4 21v-2a8 8 0 0 1 16 0v2',
  shield: 'm12 3 8 3v6c0 4-4 7-8 9-4-2-8-5-8-9V6zM8 12l3 3 5-5',
  trash: 'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7',
  edit: 'm16 3 5 5-12 12H4v-5zM13 6l5 5',
  check: 'm5 12 4 4L19 6',
  arrow: 'M4 12h16m-6-6 6 6-6 6',
  send: 'm3 3 19 9-19 9 4-9zM7 12h15',
  stop: 'M6 6h12v12H6z',
  pause: 'M8 4v16M16 4v16',
  play: 'm7 3 14 9-14 9z',
  file: 'M5 2h9l5 5v15H5zM14 2v6h5M8 13h8M8 17h5',
  extension: 'M4 4h5V3a3 3 0 0 1 6 0v1h5v5h1a3 3 0 0 1 0 6h-1v5h-5v-1a3 3 0 0 0-6 0v1H4z',
  sun: 'M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1 1M18 18l1 1M5 19l1-1M18 6l1-1',
  moon: 'M20 15A9 9 0 0 1 9 3a9 9 0 1 0 11 12',
  monitor: 'M3 4h18v13H3zM8 21h8M12 17v4',
  info: 'M12 11v6M12 7h.01M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0',
  alert: 'm12 3 10 18H2zM12 9v5M12 17h.01',
  minimize: 'M5 12h14',
  maximize: 'M5 5h14v14H5z',
  restore: 'M8 3h13v13M3 8h13v13H3z',
  keyboard: 'M2 5h20v14H2zM5 8h.01M9 8h.01M13 8h.01M17 8h.01M5 12h.01M9 12h.01M13 12h.01M17 12h.01M7 16h10',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  coffee: 'M3 8h13v8a5 5 0 0 1-5 5H8a5 5 0 0 1-5-5zM16 8h2a3 3 0 0 1 0 6h-2M6 2v3M10 2v3M14 2v3',
  undo: 'M3 4v7h7M3 11a8 8 0 1 1 2 7',
  copy: 'M9 9h12v12H9zM4 15H3V3h12v1',
  print: 'M6 9V3h12v6M6 17H3V9h18v8h-3M6 14h12v7H6z',
  terminal: 'm4 6 6 6-6 6M12 18h8',
  mail: 'M3 5h18v14H3zM3 5l9 7 9-7',
  heart: 'M20.5 5.5a5 5 0 0 0-7 0L12 7l-1.5-1.5a5 5 0 0 0-7 7L12 21l8.5-8.5a5 5 0 0 0 0-7z',
};
const icon = (name) =>
  `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${icons[name] || icons.globe}"/></svg>`;
const mark =
  '<span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 32 32"><path d="M9 9h14L9 23h14M8 16h16"/></svg></span>';
const button = (action, label, symbol, attrs = '', classes = '') =>
  `<button type="button" class="icon-button ${classes}" data-action="${action}" aria-label="${esc(label)}" title="${esc(label)}" ${attrs}>${icon(symbol)}</button>`;
const primary = (action, label, symbol = '', attrs = '') =>
  `<button type="button" class="primary" data-action="${action}" ${attrs}>${symbol ? icon(symbol) : ''}${esc(label)}</button>`;
const secondary = (action, label, symbol = '', attrs = '') =>
  `<button type="button" class="secondary" data-action="${action}" ${attrs}>${symbol ? icon(symbol) : ''}${esc(label)}</button>`;
const mod = window.zacro?.platform === 'darwin' ? '⌘' : 'Ctrl';
const colors = [
  ['berry', '#9d4460'],
  ['forest', '#416958'],
  ['ocean', '#486786'],
  ['clay', '#a56545'],
  ['lavender', '#786298'],
  ['slate', '#59646e'],
];
let state = null;
let toastTimer;
const ui = {
  panel: null,
  panelQuery: '',
  dialog: null,
  dialogReturn: null,
  commandQuery: '',
  commandIndex: 0,
  commandMode: 'navigate',
  commandItems: [],
  closedFolders: new Set(),
  dragTab: null,
  aiMessages: [],
  aiBusy: false,
  aiProgress: '',
  aiSources: [],
  aiContext: 'research',
  aiTabs: [],
  downloadSuggestions: new Map(),
  aiStatus: null,
  aiProfileId: null,
  panelSignature: '',
  homeSignature: '',
  selectedColor: '#75354d',
  findText: '',
  modalSubmit: null,
};
const activeSpace = () => state?.spaces.find((s) => s.id === state.activeSpaceId) || state?.spaces[0];
const activeProfile = () => state?.profiles.find((p) => p.id === activeSpace()?.profileId);
const activeTab = () => state?.tabs.find((t) => t.id === state.activeTabId);
const currentTabs = () => state?.tabs.filter((t) => t.spaceId === state.activeSpaceId) || [];
const profileItems = (key) => (state?.[key] || []).filter((item) => item.profileId === activeProfile()?.id);
function hostname(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '') || 'New tab';
  } catch {
    return url || 'New tab';
  }
}
function displayURL(url) {
  if (!url || url === 'zacro://newtab') return 'Search or enter a URL';
  try {
    const u = new URL(url);
    return `${u.host}${u.pathname === '/' ? '' : u.pathname}${u.search}`;
  } catch {
    return url;
  }
}
function favicon(url, tabId) {
  if (url === 'zacro://newtab') return `<span class="favicon" aria-hidden="true">${icon('sparkle')}</span>`;
  const profileId = activeProfile()?.id;
  const tabs = (state?.tabs || []).filter(
    (tab) => tab.profileId === profileId && tab.url === url && (!tabId || tab.id === tabId),
  );
  const data = tabs
    .map((tab) => state.runtime?.pages?.[tab.id]?.favicon)
    .find(
      (value) =>
        typeof value === 'string' && /^data:image\/(?:png|x-icon);base64,[A-Za-z0-9+/=]+$/.test(value),
    );
  const domain = hostname(url);
  const tone = [...domain].reduce((sum, char) => sum + char.charCodeAt(0), 0) % 6;
  return `<span class="favicon favicon-tone-${tone}" aria-hidden="true">${data ? `<img src="${data}" alt="" draggable="false" data-fallback="${esc(domain.slice(0, 1).toUpperCase())}">` : esc(domain.slice(0, 1).toUpperCase())}</span>`;
}
function dateLabel(time) {
  const d = new Date(time);
  if (Number.isNaN(d.getTime())) return '';
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return 'Today';
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  return d.toDateString() === yesterday.toDateString()
    ? 'Yesterday'
    : d.toLocaleDateString(undefined, {
        month: 'short',
        day: 'numeric',
        year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric',
      });
}
function bytes(value) {
  if (!Number.isFinite(value) || value < 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (value >= 1024 && i < 3) {
    value /= 1024;
    i++;
  }
  return `${value.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}
function toast(message, error = false) {
  clearTimeout(toastTimer);
  $('#toast-root').innerHTML =
    `<div class="toast ${error ? 'error' : ''}">${icon(error ? 'alert' : 'check')}<span>${esc(message)}</span></div>`;
  toastTimer = setTimeout(() => $('#toast-root').replaceChildren(), error ? 8000 : 4200);
}
async function invoke(action, payload = {}) {
  try {
    if (!window.zacro)
      throw new Error('The desktop browser connection is unavailable. Launch Zacro with npm start.');
    const result = await window.zacro.invoke(action, payload);
    if (result?.error) throw new Error(result.error);
    return result;
  } catch (error) {
    toast(error.message || String(error), true);
    throw error;
  }
}
function safely(promise) {
  Promise.resolve(promise).catch(() => {});
}
function clearPageBackdrop() {
  const backdrop = $('#page-backdrop');
  if (backdrop) {
    backdrop.replaceChildren();
    backdrop.hidden = true;
  }
}
function showPageBackdrop(frames) {
  clearPageBackdrop();
  if (!ui.dialog || activeProfile()?.private || !Array.isArray(frames)) return;
  const root = $('#page-backdrop');
  for (const frame of frames.slice(0, 2)) {
    const bounds = frame?.bounds;
    if (
      !bounds ||
      !['x', 'y', 'width', 'height'].every((key) => Number.isFinite(bounds[key])) ||
      bounds.width <= 0 ||
      bounds.height <= 0
    )
      continue;
    if (
      typeof frame.dataUrl !== 'string' ||
      frame.dataUrl.length > 2_000_000 ||
      !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(frame.dataUrl)
    )
      continue;
    const picture = document.createElement('img');
    picture.alt = '';
    picture.draggable = false;
    picture.src = frame.dataUrl;
    Object.assign(picture.style, {
      left: `${bounds.x}px`,
      top: `${bounds.y}px`,
      width: `${bounds.width}px`,
      height: `${bounds.height}px`,
    });
    picture.addEventListener('error', () => picture.remove(), { once: true });
    root.append(picture);
  }
  root.hidden = !root.children.length;
}
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const activeMotions = new Set();
reducedMotion.addEventListener('change', (event) => {
  if (!event.matches) return;
  // Finishing preserves close/focus callbacks when the OS preference changes
  // midway through a transition. Cancelling would leave closing panels open.
  for (const animation of activeMotions) animation.finish();
});
function motion(element, frames, duration = 200) {
  if (!element || reducedMotion.matches || !element.animate) return null;
  const animation = element.animate(frames, {
    duration,
    easing: 'cubic-bezier(.2,.8,.2,1)',
    fill: 'none',
  });
  activeMotions.add(animation);
  const forget = () => activeMotions.delete(animation);
  animation.finished.then(forget, forget);
  return animation;
}
function focusDescriptor(element = document.activeElement) {
  return element
    ? {
        element,
        id: element.id,
        key: element.dataset?.key,
        action: element.dataset?.action,
        itemId: element.dataset?.id,
        panel: element.dataset?.panel,
      }
    : null;
}
function restoreFocus(descriptor) {
  const available = (element) =>
    element?.isConnected &&
    !element.disabled &&
    !element.closest('[inert]') &&
    element.getClientRects().length;
  let element = descriptor?.element;
  if (!available(element) && descriptor?.id) element = document.getElementById(descriptor.id);
  if (!available(element) && descriptor?.key)
    element = $$('[data-key]').find((item) => item.dataset.key === descriptor.key);
  if (!available(element) && descriptor?.action)
    element = $$('[data-action]').find(
      (item) =>
        item.dataset.action === descriptor.action &&
        item.dataset.id === descriptor.itemId &&
        item.dataset.panel === descriptor.panel,
    );
  if (!available(element))
    element = available($('#home-query')) ? $('#home-query') : $('[data-key="address"]');
  element?.focus({ preventScroll: true });
}
function isolateDialog(active) {
  for (const selector of ['#sidebar', '#toolbar', '#workspace', '#side-panel', '#findbar'])
    $(selector).inert = active;
}
function restoreFocusAround(callback) {
  const focused = document.activeElement;
  const key = focused?.dataset?.key;
  callback();
  if (key && document.activeElement === document.body)
    $$('[data-key]')
      .find((el) => el.dataset.key === key)
      ?.focus({ preventScroll: true });
}
function setTheme() {
  const theme = state.settings.theme;
  const dark = theme === 'dark' || (theme === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  const base = activeSpace()?.color;
  document.documentElement.style.setProperty(
    '--space-color',
    /^#[\da-f]{6}$/i.test(base || '') ? base : '#9d4460',
  );
  if (/^#[\da-f]{6}$/i.test(base || '')) {
    const rgb = [1, 3, 5].map((i) => parseInt(base.slice(i, i + 2), 16));
    if (dark) {
      const light = rgb.map((v) => Math.round(v * 0.52 + 255 * 0.48));
      document.documentElement.style.setProperty('--accent', `rgb(${light.join(',')})`);
      document.documentElement.style.setProperty(
        '--accent-soft',
        `rgb(${rgb.map((v) => Math.round(v * 0.35 + 25)).join(',')})`,
      );
    } else {
      document.documentElement.style.setProperty('--accent', base);
      document.documentElement.style.setProperty(
        '--accent-soft',
        `rgb(${rgb.map((v) => Math.round(v * 0.15 + 255 * 0.85)).join(',')})`,
      );
    }
  }
}
function applyState(next) {
  if (!next?.profiles || !next?.tabs) return;
  const previousProfile = activeProfile()?.id;
  const previousSpace = state?.activeSpaceId;
  const previousTab = state?.activeTabId;
  state = next;
  setTheme();
  if (previousSpace !== state.activeSpaceId || previousTab !== state.activeTabId) clearPageBackdrop();
  if (previousProfile && previousProfile !== activeProfile()?.id) {
    ui.aiMessages = [];
    ui.aiSources = [];
    ui.aiTabs = [];
    ui.aiContext = 'research';
    ui.aiProfileId = activeProfile()?.id;
    ui.panelSignature = '';
    safely(invoke('ai:reset'));
  }
  render();
  if (previousSpace && previousSpace !== state.activeSpaceId) {
    motion(
      $('.space-header'),
      [
        { opacity: 0.35, transform: 'translateY(5px)' },
        { opacity: 1, transform: 'translateY(0)' },
      ],
      260,
    );
    motion(
      $('.tabs-scroll'),
      [
        { opacity: 0, transform: 'translateX(10px)' },
        { opacity: 1, transform: 'translateX(0)' },
      ],
      280,
    );
    motion(
      $('.newtab-inner'),
      [
        { opacity: 0.3, transform: 'translateY(8px)' },
        { opacity: 1, transform: 'translateY(0)' },
      ],
      320,
    );
  }
}
function render() {
  if (!state) return;
  restoreFocusAround(() => {
    renderSidebar();
    renderToolbar();
    renderWorkspace();
    renderPanel();
  });
  syncLayout();
}
function renderSidebar() {
  const space = activeSpace();
  const profile = activeProfile();
  const tabs = currentTabs();
  const pins = tabs.filter((t) => t.pinned);
  const loose = tabs.filter((t) => !t.pinned && !t.folderId);
  const folders = state.folders.filter((f) => f.spaceId === space?.id);
  const spaces = state.spaces.filter((s) => s.profileId === profile?.id);
  const signature = JSON.stringify([
    space,
    profile,
    tabs,
    folders,
    spaces,
    state.activeTabId,
    ui.panel,
    [...ui.closedFolders],
    tabs.map((tab) => [
      tab.id,
      state.runtime?.pages?.[tab.id]?.loading,
      state.runtime?.pages?.[tab.id]?.audible,
      state.runtime?.pages?.[tab.id]?.muted,
      state.runtime?.pages?.[tab.id]?.favicon,
    ]),
    state.runtime?.splitTabId,
  ]);
  if (signature === ui.sidebarSignature) return;
  ui.sidebarSignature = signature;
  const scroll = $('.tabs-scroll')?.scrollTop || 0;
  const oldRows = new Map(
    $$('[data-tab-id]', $('#sidebar')).map((row) => [row.dataset.tabId, row.getBoundingClientRect().top]),
  );
  const sameSpace = ui.sidebarSpaceId === space?.id;
  const tabRow = (tab) => {
    const page = state.runtime?.pages?.[tab.id];
    return `<div class="tab-row ${tab.id === state.activeTabId ? 'active' : ''}" draggable="true" data-tab-id="${esc(tab.id)}" data-drop-tab="${esc(tab.id)}"><button type="button" class="tab-main" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="tab-${esc(tab.id)}" ${tab.id === state.activeTabId ? 'aria-current="page"' : ''} title="${esc(tab.title)} — ${esc(tab.url)}">${page?.loading ? '<span class="spinner"></span>' : favicon(tab.url)}<span class="title">${esc(tab.title || 'New tab')}</span>${state.runtime?.splitTabId === tab.id ? icon('split') : ''}</button>${page?.audible || page?.muted ? button('tab:mute', page.muted ? 'Unmute tab' : 'Mute tab', page.muted ? 'muted' : 'volume', `data-id="${esc(tab.id)}"`, 'tab-audio') : ''}${button('tab:close', `Close ${tab.title || 'tab'}`, 'close', `data-id="${esc(tab.id)}" data-key="close-${esc(tab.id)}"`, 'tab-close')}</div>`;
  };
  $('#sidebar').innerHTML =
    `<div class="brand">${mark}<span class="brand-name">Zacro</span>${button('ui:menu', 'Browser menu', 'more', 'data-key="browser-menu"')}</div>
    <div class="space-header"><button type="button" class="space-picker" data-action="ui:spaces" data-key="space-picker" aria-label="Switch Space or profile"><span class="space-emblem">${profile?.private ? icon('shield') : esc((space?.name || 'S').slice(0, 1).toUpperCase())}</span><span class="grow"><span class="space-title">${esc(space?.name || 'My Space')}</span><span class="profile-caption">${profile?.private ? 'Private session' : esc(profile?.name || 'Default') + ' profile'}</span></span>${icon('down')}</button></div>
    <button type="button" class="sidebar-search" data-action="ui:command" data-key="sidebar-search">${icon('search')}<span>Search or jump to…</span><kbd>${mod} K</kbd></button>
    <div class="tabs-scroll"><div class="section-label">Favorites${button('ui:pin-help', 'Pin the current tab', 'plus', '', 'small-button')}</div>
    ${pins.length ? `<div class="favorites">${pins.map((tab) => `<button type="button" class="favorite ${tab.id === state.activeTabId ? 'active' : ''}" draggable="true" data-tab-id="${esc(tab.id)}" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="pin-${esc(tab.id)}" aria-label="${esc(tab.title || hostname(tab.url))}" title="${esc(tab.title)} — ${esc(tab.url)}">${favicon(tab.url)}<span>${esc(tab.title || hostname(tab.url))}</span></button>`).join('')}</div>` : `<button type="button" class="favorites-empty" data-action="ui:pin-help">${icon('pin')}<span>Keep your go-to pages here.</span></button>`}
    <div class="tabs-section-header"><div class="section-label">Your tabs<span class="tab-count">${tabs.filter((t) => !t.pinned).length}</span></div>${button('ui:new-folder', 'New folder', 'folderPlus', '', 'small-button')}</div>
    ${folders
      .map(
        (folder) =>
          `<div class="folder" data-folder-id="${esc(folder.id)}" data-drop-folder="${esc(folder.id)}"><button type="button" class="folder-heading" data-action="ui:folder-toggle" data-id="${esc(folder.id)}" data-key="folder-${esc(folder.id)}" aria-expanded="${!ui.closedFolders.has(folder.id)}">${icon(ui.closedFolders.has(folder.id) ? 'forward' : 'down')}${icon('folder')}<span class="truncate">${esc(folder.name)}</span><span class="folder-count">${tabs.filter((t) => t.folderId === folder.id).length}</span></button>${
            ui.closedFolders.has(folder.id)
              ? ''
              : `<div class="folder-tabs">${
                  tabs
                    .filter((t) => t.folderId === folder.id && !t.pinned)
                    .map(tabRow)
                    .join('') || '<div class="empty-tabs">Drop a tab into this folder</div>'
                }</div>`
          }</div>`,
      )
      .join('')}
    <div class="loose-tabs" data-drop-folder="">${loose.map(tabRow).join('')}${!loose.length && !folders.length ? '<p class="empty-tabs">A fresh start for this Space.</p>' : ''}</div>
    <button type="button" class="new-tab" data-action="ui:new-tab" data-key="new-tab">${icon('plus')}<span>New tab</span><kbd>${mod} T</kbd></button></div>
    <footer class="sidebar-footer">${profile?.private ? '<div class="private-indicator">Private tabs stay in this session.</div>' : ''}<div class="space-switcher"><div class="space-dots" aria-label="Your Spaces">${spaces.map((s) => `<button type="button" class="space-dot ${s.id === space?.id ? 'active' : ''}" data-action="space:activate" data-id="${esc(s.id)}" title="${esc(s.name)}" aria-label="Switch to ${esc(s.name)}" ${s.id === space?.id ? 'aria-current="true"' : ''}>${esc(s.name.slice(0, 1).toUpperCase())}</button>`).join('')}${button('ui:new-space', 'New Space', 'plus', '', 'small-button')}</div>${button('ui:spaces', 'Manage Spaces', 'layers', 'data-key="manage-spaces"', 'small-button')}</div><div class="footer-actions">${[
      ['history', 'History', 'history'],
      ['bookmarks', 'Bookmarks', 'bookmark'],
      ['downloads', 'Downloads', 'download'],
      ['archive', 'Archived tabs', 'archive'],
      ['settings', 'Settings', 'settings'],
    ]
      .map(([panel, label, symbol]) =>
        button(
          'ui:panel',
          label,
          symbol,
          `data-panel="${panel}" data-key="panel-${panel}" aria-pressed="${ui.panel === panel}"`,
        ),
      )
      .join('')}</div></footer>`;
  $('.tabs-scroll').scrollTop = scroll;
  if (sameSpace)
    for (const row of $$('[data-tab-id]', $('#sidebar'))) {
      const before = oldRows.get(row.dataset.tabId);
      if (before === undefined)
        motion(
          row,
          [
            { opacity: 0, transform: 'translateY(-5px) scale(.97)' },
            { opacity: 1, transform: 'translateY(0) scale(1)' },
          ],
          220,
        );
      else {
        const dy = before - row.getBoundingClientRect().top;
        if (Math.abs(dy) > 1 && Math.abs(dy) < 300)
          motion(row, [{ transform: `translateY(${dy}px)` }, { transform: 'translateY(0)' }], 190);
      }
    }
  ui.sidebarSpaceId = space?.id;
}
function renderToolbar() {
  const tab = state.runtime?.peek
    ? { ...activeTab(), url: state.runtime.peek.url, title: state.runtime.peek.title }
    : activeTab();
  const page = state.runtime?.page || {};
  const blank = !tab || tab.url === 'zacro://newtab';
  const bookmarked = profileItems('bookmarks').some((b) => b.url === tab?.url);
  const secure = tab?.url?.startsWith('https:');
  const signature = JSON.stringify([
    tab?.url,
    tab?.title,
    page.loading,
    page.canGoBack,
    page.canGoForward,
    bookmarked,
    state.runtime?.splitTabId,
    state.runtime?.maximized,
    ui.panel,
  ]);
  if (signature === ui.toolbarSignature) return;
  ui.toolbarSignature = signature;
  $('#toolbar').innerHTML =
    `<div class="navigation">${button('back', 'Back (Alt + Left)', 'back', `data-key="back" ${page.canGoBack ? '' : 'disabled'}`)}${button('forward', 'Forward (Alt + Right)', 'forward', `data-key="forward" ${page.canGoForward ? '' : 'disabled'}`)}${button(page.loading ? 'stop' : 'reload', page.loading ? 'Stop loading' : 'Reload (Ctrl + R)', page.loading ? 'close' : 'reload', `data-key="reload" ${blank ? 'disabled' : ''}`)}</div><button type="button" class="address-button" data-action="ui:address" data-key="address" title="${esc(tab?.url || 'Search or enter a URL')}" aria-label="Address bar: ${esc(tab?.url || 'New tab')}">${icon(blank ? 'search' : secure ? 'lock' : 'globe')}<span class="address-text">${esc(blank ? 'Search or enter a URL' : displayURL(tab.url))}</span></button><div class="toolbar-actions">${button('bookmark:toggle', bookmarked ? 'Remove bookmark' : 'Bookmark this page', 'star', `data-key="bookmark" data-url="${esc(tab?.url || '')}" data-title="${esc(tab?.title || '')}" aria-pressed="${bookmarked}" ${blank ? 'disabled' : ''}`)}${button('ui:split', state.runtime?.splitTabId ? 'Close split view' : 'Split view', 'split', `data-key="split" aria-pressed="${Boolean(state.runtime?.splitTabId)}"`, 'optional')}${button('ui:panel', 'Ask Zacro', 'sparkle', `data-panel="ai" data-key="panel-ai" aria-pressed="${ui.panel === 'ai'}"`)}</div><div class="window-controls" aria-label="Window controls">${button('window:minimize', 'Minimize', 'minimize')}${button('window:maximize', 'Maximize or restore', state.runtime?.maximized ? 'restore' : 'maximize')}${button('window:close', 'Close window', 'close', '', 'close-window')}</div>`;
}
function renderWorkspace() {
  const tab = activeTab();
  const blank = !tab || tab.url === 'zacro://newtab';
  const page = state.runtime?.page || {};
  $('#newtab').hidden = !blank;
  const signature = JSON.stringify([
    state.activeTabId,
    state.activeSpaceId,
    profileItems('bookmarks'),
    profileItems('history').slice(0, 8),
    state.tabs
      .filter((tab) => tab.profileId === activeProfile()?.id)
      .map((tab) => state.runtime?.pages?.[tab.id]?.favicon),
    currentTabs().filter((tab) => tab.pinned),
    state.settings.searchEngine,
    activeProfile()?.private,
  ]);
  if (blank && signature !== ui.homeSignature) {
    ui.homeSignature = signature;
    renderHome();
  }
  const error = page.error;
  $('#page-status').hidden = !error || blank;
  if (error && !blank) {
    const message =
      typeof error === 'object'
        ? error.description || error.message || 'The page could not be loaded.'
        : error;
    $('#page-status').innerHTML =
      `<div class="error-card"><div class="error-symbol">${icon('globe')}</div><h2>This page couldn’t be reached.</h2><p>${esc(message)}</p><code>${esc(hostname(tab?.url))}</code><div class="row">${primary('reload', 'Try again', 'reload')}${secondary('ui:address', 'Edit address', 'edit')}</div></div>`;
  }
  let bar = $('.loading-bar', $('#workspace'));
  if (page.loading && !blank) {
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'loading-bar';
      $('#workspace').append(bar);
    }
  } else bar?.remove();
  const peek = state.runtime?.peek;
  $('#peek').hidden = !peek;
  const peekSignature = JSON.stringify(peek);
  if (peek && peekSignature !== ui.peekSignature) {
    $('#peek').innerHTML =
      `<div class="peek-bar"><span class="peek-label">Peek</span><span class="peek-url">${esc(peek.title || peek.url)}</span>${button('peek:promote', 'Open preview as a tab', 'external')}${button('peek:close', 'Close preview (Escape)', 'close', 'data-key="peek-close"')}</div><div class="peek-body">${peek.error ? `<div class="error-card"><div class="error-symbol">${icon('globe')}</div><h2>This preview couldn’t be loaded.</h2><p>${esc(peek.error.description || peek.error.message || 'Check the address and your connection.')}</p>${primary('reload', 'Try again', 'reload')}</div>` : ''}</div>`;
  }
  ui.peekSignature = peekSignature;
}
function renderHome() {
  const draft = $('#home-query')?.value || '';
  const focused = document.activeElement?.id === 'home-query';
  const now = new Date();
  const profile = activeProfile();
  const greeting =
    now.getHours() < 12 ? 'Good morning.' : now.getHours() < 18 ? 'Good afternoon.' : 'Good evening.';
  const saved = [...currentTabs().filter((tab) => tab.pinned), ...profileItems('bookmarks')];
  const seen = new Set();
  const links = saved
    .filter((item) => {
      if (seen.has(item.url)) return false;
      seen.add(item.url);
      return true;
    })
    .slice(0, 4);
  const suggestions = [
    { title: 'Wikipedia', url: 'https://www.wikipedia.org/' },
    { title: 'GitHub', url: 'https://github.com/' },
    { title: 'Hacker News', url: 'https://news.ycombinator.com/' },
    { title: 'Are.na', url: 'https://www.are.na/' },
  ];
  const recentSeen = new Set();
  const recent = profileItems('history')
    .filter((item) => {
      if (recentSeen.has(item.url)) return false;
      recentSeen.add(item.url);
      return true;
    })
    .slice(0, 3);
  const artwork = `<div class="home-art" aria-hidden="true"><div class="art-glow"></div><svg class="ribbon-art" viewBox="0 0 240 180"><defs><linearGradient id="ribbon-front" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#f2d6bc"/><stop offset=".38" stop-color="#dba7b3"/><stop offset=".7" stop-color="#a17ca1"/><stop offset="1" stop-color="#655b88"/></linearGradient><linearGradient id="ribbon-back" x1="1" y1="0" x2="0" y2="1"><stop stop-color="#c6b9e5"/><stop offset=".55" stop-color="#826e9d"/><stop offset="1" stop-color="#4b405f"/></linearGradient><linearGradient id="ribbon-highlight" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#fff3e2" stop-opacity=".8"/><stop offset="1" stop-color="#d8bbda" stop-opacity="0"/></linearGradient></defs><path class="ribbon-back" d="M69 132C24 110 39 53 77 49c36-4 52 62 88 53 31-8 36-48 13-66" stroke="url(#ribbon-back)"/><path class="ribbon-front" d="M67 133c36 18 43-45 77-40 37 6 58-20 35-55" stroke="url(#ribbon-front)"/><path class="ribbon-highlight" d="M66 123c30 14 43-47 77-40 24 4 38-8 38-25" stroke="url(#ribbon-highlight)"/></svg><span class="art-spark art-spark-one"></span><span class="art-spark art-spark-two"></span></div>`;
  $('#newtab').innerHTML =
    `<div class="newtab-inner"><div class="newtab-meta"><button type="button" class="home-space" data-action="ui:spaces" data-key="home-space">${profile?.private ? icon('shield') : '<span class="space-status-dot"></span>'}${esc(activeSpace()?.name || 'My Space')}${icon('down')}</button><div class="home-date"><span class="time-label">${esc(now.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }))}</span><span class="date-line">${esc(now.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }))}</span></div></div>
    <div class="hero home-header"><div><h1>${profile?.private ? 'A little privacy.' : greeting}</h1><p class="hero-copy">${profile?.private ? 'Your history and tabs stay in this session.' : 'Where will your curiosity take you?'}</p></div>${artwork}</div>
    <form id="home-search" class="home-search" autocomplete="off">${icon('search')}<input id="home-query" name="query" aria-label="Search the web or enter a URL" placeholder="Search the web or enter a URL" spellcheck="false"><kbd>${mod} L</kbd><button type="submit" class="icon-button" title="Go" aria-label="Go">${icon('arrow')}</button></form>
    <div class="search-caption"><span><kbd>Enter</kbd> to search or navigate</span><button type="button" class="home-ask" data-action="ui:home-ask">${icon('sparkle')}Ask Zacro<kbd>${mod} ↵</kbd></button></div>
    <div class="home-links-title"><h2>${links.length ? 'Your go-to places' : 'Start exploring'}</h2><button type="button" class="text-button" data-action="ui:panel" data-panel="bookmarks" data-key="home-bookmarks">${links.length ? 'All bookmarks' : 'Save your favorites'}${icon('forward')}</button></div>
    <div class="home-links">${(links.length ? links : suggestions).map((link) => `<button type="button" class="home-link" data-action="navigate" data-url="${esc(link.url)}" title="${esc(link.url)}">${favicon(link.url)}<span class="home-link-label">${esc(link.title || hostname(link.url))}</span><span class="home-link-domain">${esc(hostname(link.url))}</span>${icon('external')}</button>`).join('')}</div>
    ${recent.length ? `<div class="home-recent"><div class="home-links-title"><h2>Pick up where you left off</h2><button type="button" class="text-button" data-action="ui:panel" data-panel="history" data-key="home-history">History${icon('forward')}</button></div><div class="recent-list">${recent.map((item) => `<button type="button" class="recent-page" data-action="navigate" data-url="${esc(item.url)}">${favicon(item.url)}<span class="grow"><span class="recent-title">${esc(item.title || hostname(item.url))}</span><span class="recent-domain">${esc(hostname(item.url))}</span></span><span class="recent-time">${esc(dateLabel(item.visitedAt))}</span>${icon('arrow')}</button>`).join('')}</div></div>` : `<div class="home-discover"><span class="discover-symbol">${icon('layers')}</span><span class="grow"><strong>A Space for every part of your day.</strong><span>Keep work, projects, and the good stuff together.</span></span><button type="button" class="text-button" data-action="ui:new-space">New Space${icon('plus')}</button></div>`}
    <div class="home-bottom"><div class="home-quick-actions"><button type="button" data-action="ui:panel" data-panel="downloads" data-key="home-downloads">${icon('download')}Downloads</button><button type="button" data-action="ui:panel" data-panel="archive" data-key="home-archive">${icon('archive')}Archived tabs</button></div><button type="button" class="text-button" data-action="ui:shortcuts">${icon('keyboard')}Shortcuts</button></div></div>`;
  if (draft) $('#home-query').value = draft;
  if (focused) $('#home-query').focus({ preventScroll: true });
}

let lastLayout = '';
function syncLayout() {
  if (!state) return;
  const width = Math.max(210, Math.min(340, Number(state.settings.sidebarWidth) || 260));
  const panel = ui.panel ? Math.max(300, Math.min(400, window.innerWidth - width - 328)) : 0;
  $('#app').dataset.panelOpen = String(Boolean(ui.panel));
  document.documentElement.style.setProperty('--sidebar', `${width}px`);
  document.documentElement.style.setProperty('--panel', `${panel}px`);
  const layout = {
    sidebarWidth: width,
    panelWidth: panel,
    overlay: Boolean(ui.dialog),
    peek: Boolean(state.runtime?.peek),
  };
  const signature = JSON.stringify(layout);
  if (signature !== lastLayout) {
    lastLayout = signature;
    safely(invoke('layout', layout));
  }
}
function empty(symbol, title, description) {
  return `<div class="empty-state"><div class="empty-icon">${icon(symbol)}</div><h3>${esc(title)}</h3><p>${esc(description)}</p></div>`;
}
const panelNames = {
  history: ['history', 'History'],
  bookmarks: ['bookmark', 'Bookmarks'],
  downloads: ['download', 'Downloads'],
  archive: ['archive', 'Archived tabs'],
  settings: ['settings', 'Settings'],
  extensions: ['extension', 'Extensions'],
  ai: ['sparkle', 'Ask Zacro'],
};
function panelHeader() {
  const [symbol, title] = panelNames[ui.panel] || ['info', 'Library'];
  return `<header class="panel-header">${icon(symbol)}<h2 id="panel-title" tabindex="-1">${title}</h2>${ui.panel === 'ai' ? button('ui:ai-reset', 'New conversation', 'plus') : ''}${button('ui:panel-close', 'Close panel', 'close', 'data-key="panel-close"')}</header>`;
}
function renderPanel(force = false) {
  const element = $('#side-panel');
  element.hidden = !ui.panel;
  if (!ui.panel) return;
  element.setAttribute('aria-label', panelNames[ui.panel][1]);
  const data =
    ui.panel === 'settings'
      ? [state.profiles, state.spaces, activeProfile()?.id]
      : ui.panel === 'ai'
        ? [
            ui.aiMessages,
            ui.aiBusy,
            ui.aiProgress,
            ui.aiStatus,
            ui.aiContext,
            ui.aiTabs,
            state.runtime?.aiConfigured,
          ]
        : [state[ui.panel === 'archive' ? 'archive' : ui.panel], ui.panelQuery, activeProfile()?.id];
  const signature = JSON.stringify([ui.panel, data]);
  if (!force && signature === ui.panelSignature) return;
  ui.panelSignature = signature;
  const scroll = $('.panel-body', element)?.scrollTop || 0;
  const draft = $('#ai-question', element)?.value;
  const providerDraft = Object.fromEntries(
    $$('#provider-form input,#provider-form select', element).map((el) => [el.id, el.value]),
  );
  const focused = document.activeElement;
  const focusedId = element.contains(focused) ? focused.id : null;
  const selection =
    focusedId && 'selectionStart' in focused ? [focused.selectionStart, focused.selectionEnd] : null;
  if (ui.panel === 'settings') {
    element.innerHTML = panelHeader() + `<div class="panel-body">${renderSettings()}</div>`;
  } else if (ui.panel === 'extensions') {
    element.innerHTML = panelHeader() + `<div class="panel-body">${renderExtensions()}</div>`;
  } else if (ui.panel === 'ai') {
    element.innerHTML = panelHeader() + renderAI();
  } else {
    const label = panelNames[ui.panel][1];
    element.innerHTML =
      panelHeader() +
      `<div class="panel-toolbar"><input id="panel-search" type="search" placeholder="Search ${label.toLowerCase()}" aria-label="Search ${label.toLowerCase()}" value="${esc(ui.panelQuery)}">${ui.panel === 'history' ? button('ui:history-clear', 'Clear history', 'trash') : ui.panel === 'archive' ? button('ui:archive-clear', 'Empty archive', 'trash') : ''}</div><div class="panel-body">${renderResourcePanel()}</div>`;
  }
  const body = $('.panel-body', element);
  if (body) body.scrollTop = scroll;
  if (draft !== undefined && $('#ai-question', element)) $('#ai-question', element).value = draft;
  for (const [id, value] of Object.entries(providerDraft)) {
    const field = $('#' + id, element);
    if (field) field.value = value;
  }
  if (focusedId) {
    const replacement = $(`#${focusedId}`);
    if (replacement) {
      replacement.focus({ preventScroll: true });
      if (selection && replacement.setSelectionRange)
        try {
          replacement.setSelectionRange(...selection);
        } catch {}
    }
  }
}
function renderResourcePanel() {
  const key = ui.panel;
  const query = ui.panelQuery.trim().toLowerCase();
  let records = profileItems(key).filter((item) =>
    `${item.title || item.name || item.filename || ''} ${item.url || ''}`.toLowerCase().includes(query),
  );
  if (key === 'downloads') return renderDownloads(records);
  if (!records.length) {
    if (query) return empty('search', 'No matches', 'Try a different title or address.');
    const messages = {
      history: [
        'history',
        'A fresh start',
        'The pages you visit will appear here. Private browsing never adds history.',
      ],
      bookmarks: [
        'bookmark',
        'Keep the good finds',
        'Use the star in the address bar to save a page for later.',
      ],
      archive: [
        'archive',
        'Nothing left behind',
        'Closed and automatically archived tabs wait here, ready to reopen.',
      ],
    };
    return empty(...messages[key]);
  }
  let lastDate = '';
  return records
    .slice(0, 500)
    .map((item) => {
      const date = dateLabel(item.visitedAt || item.archivedAt || item.createdAt);
      const heading =
        key !== 'bookmarks' && date !== lastDate ? `<div class="list-label">${esc(date)}</div>` : '';
      lastDate = date;
      return (
        heading +
        `<div class="resource">${favicon(item.url)}<button type="button" class="resource-main" data-action="${key === 'archive' ? 'tab:restore' : 'ui:open-url'}" data-id="${esc(item.id)}" data-url="${esc(item.url)}" title="${esc(item.url)}"><div class="resource-title">${esc(item.title || hostname(item.url))}</div><div class="resource-meta">${esc(hostname(item.url))}${key === 'history' ? ` · ${esc(new Date(item.visitedAt).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }))}` : ''}</div></button><div class="resource-actions">${key === 'bookmarks' ? button('bookmark:delete', 'Remove bookmark', 'close', `data-id="${esc(item.id)}"`) : key === 'archive' ? button('tab:restore', 'Restore tab', 'undo', `data-id="${esc(item.id)}"`) : button('peek:open', 'Preview page', 'eye', `data-url="${esc(item.url)}"`)}</div></div>`
      );
    })
    .join('');
}
function renderDownloads(records) {
  if (!records.length)
    return empty(
      'download',
      'Your downloads live here',
      'Download a file from any page to track its progress and find it again.',
    );
  return records
    .map((file) => {
      const name = file.name || file.filename || 'Download';
      const status = file.state || file.status || 'progressing';
      const progress =
        Number(file.totalBytes) > 0
          ? Math.round((Number(file.receivedBytes || 0) / file.totalBytes) * 100)
          : 0;
      const complete = status === 'completed';
      const paused = file.paused || status === 'paused';
      const running = ['progressing', 'paused'].includes(status);
      return `<div class="resource"><span class="download-file">${icon('file')}</span><div class="grow"><div class="resource-title" title="${esc(name)}">${esc(name)}</div><div class="resource-meta">${esc(complete ? bytes(file.totalBytes || file.receivedBytes) : status === 'cancelled' ? 'Cancelled' : status === 'interrupted' ? 'Interrupted' : paused ? 'Paused' : `${bytes(file.receivedBytes || 0)}${file.totalBytes > 0 ? ' / ' + bytes(file.totalBytes) : ''}`)}</div>${running ? `<div class="download-progress"><progress max="100" value="${progress}" aria-label="Download progress"></progress></div>` : ''}<div class="download-operations">${complete ? `<button type="button" class="text-button" data-action="download:show" data-id="${esc(file.id)}">Show in folder</button><button type="button" class="text-button" data-action="ui:download-rename" data-id="${esc(file.id)}">Rename</button><button type="button" class="text-button" data-action="ui:download-suggest" data-id="${esc(file.id)}">${icon('sparkle')}${ui.downloadSuggestions.has(file.id) ? 'Review name' : 'Suggest name'}</button>${file.originalName || file.previousPath || file.previousName ? `<button type="button" class="text-button" data-action="download:undo" data-id="${esc(file.id)}">Undo rename</button>` : ''}` : running ? `<button type="button" class="text-button" data-action="download:${paused ? 'resume' : 'pause'}" data-id="${esc(file.id)}">${paused ? 'Resume' : 'Pause'}</button><button type="button" class="text-button danger" data-action="download:cancel" data-id="${esc(file.id)}">Cancel</button>` : ''}</div></div></div>`;
    })
    .join('');
}
function selectOptions(values, current) {
  return values
    .map(
      ([value, label]) =>
        `<option value="${esc(value)}" ${String(value) === String(current) ? 'selected' : ''}>${esc(label)}</option>`,
    )
    .join('');
}
function settingSelect(key, label, values) {
  return `<div class="setting-field"><label for="setting-${key}">${label}</label><select id="setting-${key}" data-setting="${key}">${selectOptions(values, state.settings[key])}</select></div>`;
}
function renderSettings() {
  const settings = state.settings;
  const profile = activeProfile();
  return `<div class="panel-intro">Make a browser that feels like yours.</div><section class="setting-section"><h3>Appearance & browsing</h3>${settingSelect(
    'theme',
    'Appearance',
    [
      ['system', 'Follow system'],
      ['light', 'Light'],
      ['dark', 'Dark'],
    ],
  )}${settingSelect('searchEngine', 'Search engine', [
    ['duckduckgo', 'DuckDuckGo'],
    ['google', 'Google'],
    ['bing', 'Bing'],
    ['brave', 'Brave Search'],
  ])}${settingSelect('archiveAfterHours', 'Archive inactive, unpinned tabs', [
    [0, 'Never'],
    [12, 'After 12 hours'],
    [24, 'After 24 hours'],
    [72, 'After 3 days'],
    [168, 'After 7 days'],
    [720, 'After 30 days'],
  ])}<p class="provider-note">Automatic cleanup applies to inactive tabs restored in the background. Open pages are kept to protect unsaved work.</p>${settingSelect(
    'sidebarWidth',
    'Sidebar width',
    [
      [230, 'Compact'],
      [260, 'Comfortable'],
      [300, 'Spacious'],
    ],
  )}<label class="setting-toggle"><span>Restore previous session<small>Pick up with your saved Spaces and tabs.</small></span><input type="checkbox" data-setting="restoreSession" ${settings.restoreSession ? 'checked' : ''}></label><div class="setting-actions">${secondary('ui:edit-space', 'Customize Space', 'edit')}${secondary('ui:profiles', 'Profiles', 'user')}</div></section><section class="setting-section"><h3>AI connection</h3><div id="ai-connection-status" class="connection-status"><span class="status-dot ${(ui.aiStatus?.configured ?? state.runtime?.aiConfigured) ? 'connected' : ''}"></span>${(ui.aiStatus?.configured ?? state.runtime?.aiConfigured) ? 'Provider connected' : 'No provider connected'}</div><form id="provider-form"><div class="setting-field"><label for="provider">Provider</label><select id="provider" name="provider">${selectOptions(
    [
      ['openai', 'OpenAI API'],
      ['anthropic', 'Claude API'],
    ],
    state.runtime?.aiProvider || settings.aiProvider || 'openai',
  )}</select></div><div class="setting-field"><label for="api-key">API key</label><input id="api-key" name="apiKey" type="password" autocomplete="off" spellcheck="false" placeholder="Paste your provider API key" required><small>Encrypted with your operating system. Never included in exports or sent to other providers.</small></div><div class="setting-field"><label for="ai-model">Model (optional)</label><input id="ai-model" name="model" value="${esc(state.runtime?.aiModel || settings.aiModel || '')}" placeholder="Use provider default" autocomplete="off" spellcheck="false"></div><div class="setting-actions"><button type="submit" class="primary">${icon('lock')}Save connection</button>${secondary('ui:ai-disconnect', 'Disconnect')}</div></form><p class="provider-note">API usage is billed by your provider. A ChatGPT or Claude subscription does not supply an API key. Your connection is used only when you ask a question.</p>${settingSelect(
    'openSourcesLimit',
    'Pages to open from each answer',
    [
      [1, '1 source'],
      [2, '2 sources'],
      [3, '3 sources'],
      [5, '5 sources'],
    ],
  )}<p class="provider-note">Page sharing is off by default. Choose “Current page” or select tabs in the conversation to share page or PDF text for a question. Password and form fields are excluded. Scanned and encrypted PDFs cannot be read.</p></section><section class="setting-section"><h3>Your data</h3><p class="panel-intro">Active profile: <strong>${esc(profile?.name)}</strong>. Cookies, browsing data, and permissions are isolated by profile.</p><div class="setting-actions">${secondary('data:export', 'Export data', 'external')}${secondary('data:import', 'Import data', 'download')}</div><p class="provider-note">Export your Spaces, tabs, and bookmarks. Import a Zacro backup or browser bookmark HTML file. Private sessions and AI keys are excluded.</p><div class="setting-actions">${secondary('ui:data-clear', 'Clear browsing data', 'trash')}${secondary('ui:permissions', 'Site permissions', 'shield')}</div></section><section class="setting-section"><h3>Extensions</h3><p class="panel-intro">Load compatible unpacked extensions into this profile. Supported APIs vary; Chrome Web Store installation and extension sync are not available.</p>${secondary('ui:panel', 'Manage extensions', 'extension', 'data-panel="extensions"')}</section><section class="setting-section"><h3>About Zacro</h3><p class="panel-intro">An independent, open-source browser.<br>Version ${esc(state.runtime?.version || '0.1.0')} · Built on Chromium</p><div class="setting-actions">${secondary('app:about', 'Version details', 'info')}${secondary('ui:shortcuts', 'Shortcuts', 'keyboard')}</div></section>`;
}
function renderExtensions() {
  const extensions = profileItems('extensions');
  return `<p class="panel-intro">Extensions are isolated to <strong>${esc(activeProfile()?.name)}</strong>. Install only extensions you trust and review their requested access.</p>${primary('extension:install', 'Load unpacked extension', 'plus')}<p class="provider-note">Select a local folder containing manifest.json. Electron supports a subset of Chrome extension APIs; storage.sync and Web Store installation are unavailable.</p>${extensions.length ? extensions.map((ext) => `<article class="extension-card"><div class="row"><div class="extension-icon">${icon('extension')}</div><div class="grow"><h3>${esc(ext.name || ext.id)}</h3><span class="small muted">${esc(ext.version || '')} · ${ext.enabled === false ? 'Disabled' : 'Enabled'}</span></div></div>${ext.description ? `<p>${esc(ext.description)}</p>` : ''}${ext.error ? `<p class="danger">${esc(ext.error)}</p>` : ''}<div class="row between"><button type="button" class="text-button" data-action="extension:toggle" data-id="${esc(ext.id)}">${ext.enabled === false ? 'Enable' : 'Disable'}</button><button type="button" class="text-button danger" data-action="ui:extension-remove" data-id="${esc(ext.id)}">Remove</button></div></article>`).join('') : empty('extension', 'A little extra capability', 'Your installed extensions will appear here.')}`;
}
function renderAnswer(message) {
  const text = String(message.text || '');
  const format = (raw) => {
    const parts = [];
    const expression = /\[([^\]\n]{1,200})\]\((https?:\/\/[^\s)]+)\)/g;
    let match,
      last = 0;
    while ((match = expression.exec(raw))) {
      parts.push(esc(raw.slice(last, match.index)));
      parts.push(
        `<button type="button" class="text-button" data-action="ui:open-url" data-url="${esc(match[2])}">${esc(match[1])}</button>`,
      );
      last = match.index + match[0].length;
    }
    parts.push(esc(raw.slice(last)));
    return parts.join('');
  };
  const citations = (message.citations || [])
    .filter(
      (c) =>
        Number.isInteger(c.start) &&
        Number.isInteger(c.end) &&
        c.start >= 0 &&
        c.end >= c.start &&
        c.end <= text.length &&
        /^https?:\/\//i.test(c.url || ''),
    )
    .sort((a, b) => a.end - b.end);
  if (!citations.length) return format(text);
  const parts = [];
  let cursor = 0;
  citations.forEach((citation, index) => {
    if (citation.end < cursor) return;
    const marker = text.slice(citation.start, citation.end);
    const replace = citation.start >= cursor && /^\[\d+:\d+\]$/.test(marker);
    parts.push(format(text.slice(cursor, replace ? citation.start : citation.end)));
    parts.push(
      `<button type="button" class="message-citation" data-action="ui:citation" data-url="${esc(citation.url)}" data-id="${esc(citation.tabId || '')}" data-quote="${esc(citation.quote || '')}" data-page-number="${Number(citation.pageNumber) || ''}" title="${esc((citation.title || hostname(citation.url)) + (citation.quote ? ' · ' + citation.quote : ''))}" aria-label="Open source ${index + 1}: ${esc(citation.title || hostname(citation.url))}">${index + 1}</button>`,
    );
    cursor = citation.end;
  });
  parts.push(format(text.slice(cursor)));
  return parts.join('');
}
function renderAI() {
  const privateSession = Boolean(activeProfile()?.private);
  const configured = !privateSession && Boolean(ui.aiStatus?.configured ?? state.runtime?.aiConfigured);
  const messages = ui.aiMessages;
  let body;
  if (!messages.length) {
    body = `<div class="ai-welcome"><div class="ai-welcome-symbol">${icon('sparkle')}</div><h3>Let curiosity<br>lead the way.</h3><p>${privateSession ? 'AI is unavailable in private sessions. Switch to a regular profile to start a conversation.' : configured ? 'Ask a question, explore a topic, or find another perspective. Answers come with sources you can open when you’re ready.' : 'Connect your own AI provider to research the web and ask questions about pages. Browsing stays yours, with or without AI.'}</p>${configured ? `<button type="button" class="prompt-suggestion" data-action="ui:ai-prompt" data-prompt="What are some interesting ideas in science this week?">Explore something new${icon('arrow')}</button><button type="button" class="prompt-suggestion" data-action="ui:ai-page">Ask about this page${icon('arrow')}</button><button type="button" class="prompt-suggestion" data-action="ui:ai-select-tabs">Compare selected tabs${icon('arrow')}</button>` : privateSession ? primary('ui:spaces', 'Switch profile', 'user') : primary('ui:panel', 'Connect a provider', 'settings', 'data-panel="settings"')}</div>`;
  } else {
    body = messages
      .map(
        (message) =>
          `<article class="message ${message.role}"><div class="message-role">${message.role === 'user' ? 'You' : message.error ? 'Something went wrong' : 'Zacro'}</div><div class="message-content ${message.error ? 'danger' : ''}">${message.role === 'assistant' ? renderAnswer(message) : esc(message.text)}</div>${message.warning ? `<p class="provider-note danger">${esc(message.warning)}</p>` : ''}${message.usage ? `<p class="provider-note">${Number(message.usage.inputTokens || 0).toLocaleString()} input · ${Number(message.usage.outputTokens || 0).toLocaleString()} output tokens${message.usage.searchRequests ? ' · ' + Number(message.usage.searchRequests) + ' searches' : ''}</p>` : ''}${message.sharedTabs?.length ? `<p class="provider-note">Shared: ${esc(message.sharedTabs.map((t) => t.title || t.url || t).join(', '))}</p>` : ''}${message.unreadable?.length ? `<p class="provider-note">Couldn’t read: ${esc(message.unreadable.map((t) => t.title || t.url || t.reason || t).join(', '))}</p>` : ''}${message.sources?.length ? `<div class="source-list">${message.sources.map((source, i) => `<button type="button" class="source-item" data-action="ui:open-url" data-url="${esc(source.url)}" title="${esc(source.url)}"><span class="source-index">${i + 1}</span><span class="grow truncate">${esc(source.title || hostname(source.url))}</span>${icon('external')}</button>`).join('')}</div>` : ''}${message.searchUrl ? `<button type="button" class="text-button" data-action="ui:open-url" data-url="${esc(message.searchUrl)}">${icon('search')}Open ordinary search results</button>` : ''}</article>`,
      )
      .join('');
  }
  return `<div class="panel-body conversation" id="conversation">${body}${ui.aiBusy ? `<div class="ai-progress" role="status"><span class="spinner"></span>${esc(ui.aiProgress || 'Looking into it…')}</div>` : ''}</div><div class="ai-footer">${ui.aiSources.length && !ui.aiBusy ? `<button type="button" class="secondary ai-source-action" data-action="ai:open-sources">${icon('external')}Open sources <kbd>${mod} Enter</kbd></button>` : ''}<div class="ai-context">${icon('shield')}<label for="ai-context" class="sr-only">Content to share</label><select id="ai-context" ${activeProfile()?.private ? 'disabled' : ''}>${selectOptions(
    [
      ['research', 'Web research · no page sharing'],
      ['page', 'Current page'],
      ['tabs', `Selected tabs${ui.aiTabs.length ? ' (' + ui.aiTabs.length + ')' : ''}`],
    ],
    ui.aiContext,
  )}</select>${ui.aiContext === 'tabs' ? button('ui:ai-select-tabs', 'Choose tabs', 'plus', '', 'small-button') : ''}</div>${
    ui.aiContext !== 'research'
      ? `<p class="provider-note">Sharing with ${esc(ui.aiStatus?.provider || state.settings.aiProvider || 'your provider')}: ${esc(
          ui.aiContext === 'page'
            ? activeTab()?.title || 'Current page'
            : state.tabs
                .filter((t) => ui.aiTabs.includes(t.id))
                .map((t) => t.title)
                .join(', ') || 'No tabs selected',
        )}</p>`
      : ''
  }<form id="ai-form" class="ai-composer"><textarea id="ai-question" name="question" rows="2" placeholder="${configured ? 'Ask anything…' : 'Connect a provider in Settings'}" aria-label="Ask Zacro" ${configured ? '' : 'disabled'}></textarea>${ui.aiBusy ? button('ai:cancel', 'Stop response', 'stop') : '<button type="submit" class="primary" aria-label="Send question" ' + (configured ? '' : 'disabled') + '>' + icon('arrow') + '</button>'}</form><p class="ai-help">${activeProfile()?.private ? 'AI is unavailable in private sessions.' : 'Enter to send · Shift + Enter for a new line. Answers can be mistaken; check the sources.'}</p></div>`;
}
function openPanel(panel) {
  if (!panelNames[panel]) return;
  const changed = ui.panel !== panel;
  if (!ui.panel || !$('#side-panel').contains(document.activeElement)) ui.panelReturn = focusDescriptor();
  ui.panelMotion = (ui.panelMotion || 0) + 1;
  $('#side-panel')
    .getAnimations()
    .forEach((animation) => animation.cancel());
  ui.panel = panel;
  ui.panelQuery = '';
  ui.panelSignature = '';
  render();
  if (changed)
    motion(
      $('#side-panel'),
      [
        { opacity: 0.35, transform: 'translateX(18px)' },
        { opacity: 1, transform: 'translateX(0)' },
      ],
      240,
    );
  if (panel === 'ai')
    safely(
      invoke('ai:status').then((status) => {
        ui.aiStatus = status;
        renderPanel(true);
      }),
    );
  requestAnimationFrame(() => {
    if (ui.panel === panel && !ui.dialog)
      ($('#panel-search') || $('#ai-question:not(:disabled)') || $('#panel-title'))?.focus({
        preventScroll: true,
      });
  });
}
function closePanel() {
  if (!ui.panel) return;
  const token = (ui.panelMotion = (ui.panelMotion || 0) + 1);
  const finish = () => {
    if (token !== ui.panelMotion) return;
    ui.panel = null;
    ui.panelSignature = '';
    render();
    restoreFocus(ui.panelReturn);
    ui.panelReturn = null;
  };
  const animation = motion(
    $('#side-panel'),
    [
      { opacity: 1, transform: 'translateX(0)' },
      { opacity: 0, transform: 'translateX(14px)' },
    ],
    130,
  );
  if (animation) animation.finished.then(finish).catch(() => {});
  else finish();
}
function openDialog(kind, html, { title, focus } = {}) {
  if (ui.authRequest) {
    const id = ui.authRequest;
    ui.authRequest = null;
    safely(invoke('auth:cancel', { id }));
  }
  ui.dialogReturn = ui.dialog ? ui.dialogReturn : focusDescriptor();
  ui.dialogToken = (ui.dialogToken || 0) + 1;
  ui.dialog = kind;
  $('#dialog-root').innerHTML =
    `<div class="dialog-backdrop" data-action="ui:backdrop"><section class="dialog ${kind === 'command' ? 'command-dialog' : kind === 'menu' ? 'context-menu' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title || kind)}" tabindex="-1">${html}</section></div>`;
  isolateDialog(true);
  syncLayout();
  const focusToken = ui.dialogToken;
  requestAnimationFrame(() => {
    const root = $('#dialog-root');
    if (ui.dialogToken === focusToken)
      ($(focus || 'input, select, button, textarea', root) || $('.dialog', root))?.focus();
  });
}
function closeDialog({ restore = true } = {}) {
  if (ui.authRequest) {
    const id = ui.authRequest;
    ui.authRequest = null;
    safely(invoke('auth:cancel', { id }));
  }
  const focus = ui.dialogReturn;
  ui.dialog = null;
  ui.modalSubmit = null;
  ui.dialogToken = (ui.dialogToken || 0) + 1;
  $('#dialog-root').replaceChildren();
  clearPageBackdrop();
  isolateDialog(false);
  syncLayout();
  if (restore) restoreFocus(focus);
  ui.dialogReturn = null;
}
function dismissDialog() {
  if (!ui.dialog) return;
  const token = ui.dialogToken;
  const backdrop = $('.dialog-backdrop');
  const animation = motion(
    $('.dialog'),
    [
      { opacity: 1, transform: 'translateY(0) scale(1)' },
      { opacity: 0, transform: 'translateY(6px) scale(.985)' },
    ],
    120,
  );
  motion(backdrop, [{ opacity: 1 }, { opacity: 0 }], 120);
  if (animation)
    animation.finished
      .then(() => {
        if (token === ui.dialogToken) closeDialog();
      })
      .catch(() => {});
  else closeDialog();
}

function formDialog(title, description, fields, submitLabel, onSubmit, { danger = false } = {}) {
  openDialog(
    'form',
    `<div class="dialog-header"><h2>${esc(title)}</h2>${button('ui:dialog-close', 'Close', 'close')}</div><form id="modal-form" class="dialog-body">${description ? `<p class="dialog-description">${esc(description)}</p>` : ''}${fields}<div id="modal-error" class="inline-error" role="alert"></div><div class="dialog-footer">${secondary('ui:dialog-close', 'Cancel')}<button type="submit" class="primary ${danger ? 'danger' : ''}">${esc(submitLabel)}</button></div></form>`,
    { title, focus: fields ? 'input, select, textarea' : 'button[type=submit]' },
  );
  const token = ui.dialogToken;
  const context = {
    isCurrent: () => ui.dialogToken === token && Boolean(ui.dialog),
    close: () => {
      if (ui.dialogToken !== token || !ui.dialog) return false;
      closeDialog();
      return true;
    },
  };
  ui.modalSubmit = (data) => onSubmit(data, context);
}
function confirmDialog(title, description, action, label = 'Confirm') {
  formDialog(
    title,
    description,
    '',
    label,
    async (_data, context) => {
      if (!context.isCurrent()) return;
      await action();
      if (!context.isCurrent()) return;
      if (!context.close()) return;
    },
    { danger: true },
  );
}
function field(name, label, value = '', type = 'text', extra = '') {
  return `<label class="field">${esc(label)}<input name="${name}" type="${type}" value="${esc(value)}" ${extra}></label>`;
}
function showSpaces() {
  openDialog(
    'spaces',
    `<div class="dialog-header"><h2>Your Spaces</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Different worlds. A little space for each.</p>${state.spaces
      .map((space) => {
        const profile = state.profiles.find((p) => p.id === space.profileId);
        return `<div class="space-option-wrapper"><button type="button" class="space-option ${space.id === state.activeSpaceId ? 'current' : ''}" data-action="ui:switch-space" data-id="${esc(space.id)}"><span class="space-emblem">${esc(space.name.slice(0, 1).toUpperCase())}</span><span class="grow"><div class="space-option-name">${esc(space.name)}</div><div class="space-option-profile">${esc(profile?.name)}${profile?.private ? ' · Private' : ''} · ${state.tabs.filter((t) => t.spaceId === space.id).length} tabs</div></span>${space.id === state.activeSpaceId ? icon('check') : ''}</button><div class="space-option-actions">${button('ui:edit-space', 'Edit Space', 'edit', `data-id="${esc(space.id)}"`)}${button('ui:delete-space', 'Delete Space', 'trash', `data-id="${esc(space.id)}"`)}</div></div>`;
      })
      .join(
        '',
      )}<div class="space-manager-actions">${primary('ui:new-space', 'New Space', 'plus')}${secondary('ui:profiles', 'Manage profiles', 'user')}</div></div>`,
    { title: 'Your Spaces' },
  );
}
function showSpaceForm(id) {
  const space = id ? state.spaces.find((s) => s.id === id) : null;
  ui.selectedColor = space?.color || colors[0][1];
  formDialog(
    space ? 'Customize your Space' : 'Create a Space',
    'A place for a project, a passion, or a different part of your day.',
    field(
      'name',
      'Space name',
      space?.name || '',
      'text',
      'required maxlength="60" placeholder="e.g. Work, Weekend, Research"',
    ) +
      (!space
        ? `<label class="field">Profile<select name="profileId">${selectOptions(
            state.profiles.map((p) => [p.id, p.name]),
            activeProfile()?.id,
          )}</select></label>`
        : '') +
      `<div class="field"><span>Space color</span><div class="color-options" role="group" aria-label="Space color">${colors.map(([name, color]) => `<button type="button" class="color-option swatch-${name} ${ui.selectedColor === color ? 'selected' : ''}" data-action="ui:color" data-color="${color}" aria-label="${name}" aria-pressed="${ui.selectedColor === color}"></button>`).join('')}</div></div>`,
    space ? 'Save changes' : 'Create Space',
    async (data, context) => {
      if (!context.isCurrent()) return;
      await invoke(space ? 'space:update' : 'space:create', {
        ...(space ? { id: space.id } : {}),
        name: data.get('name'),
        color: ui.selectedColor,
        ...(!space ? { profileId: data.get('profileId') } : {}),
      });
      if (!context.isCurrent()) return;
      if (!context.close()) return;
    },
  );
}
function showProfiles() {
  openDialog(
    'profiles',
    `<div class="dialog-header"><h2>Browser profiles</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Each profile keeps its accounts, cookies, history, and extensions separate.</p>${state.profiles.map((profile) => `<div class="profile-option"><div class="row"><span class="profile-avatar">${profile.private ? icon('shield') : esc(profile.name.slice(0, 1).toUpperCase())}</span><div class="grow"><strong>${esc(profile.name)}</strong><div class="profile-caption">${profile.private ? 'Private · cleared when closed' : 'Persistent profile'} · ${state.spaces.filter((s) => s.profileId === profile.id).length} Spaces</div></div>${button('ui:delete-profile', 'Delete profile', 'trash', `data-id="${esc(profile.id)}"`)}</div></div>`).join('')}<div class="space-manager-actions">${primary('ui:new-profile', 'New profile', 'plus')}${secondary('ui:new-private', 'Private session', 'shield')}</div></div>`,
    { title: 'Browser profiles' },
  );
}
function showMenu() {
  const action = (name, label, symbol, key = '') =>
    `<button type="button" class="context-action" data-action="${name}">${icon(symbol)}${label}${key ? `<kbd>${key}</kbd>` : ''}</button>`;
  openDialog(
    'menu',
    `<div class="dialog-body">${action('ui:new-tab', 'New tab', 'plus', mod + ' T')}${action('ui:new-private', 'New private session', 'shield')}${action('ui:spaces', 'Spaces & profiles', 'user')}<hr class="context-separator">${action('ui:find', 'Find on page', 'search', mod + ' F')}${action('ui:zoom-in', 'Zoom in', 'plus', mod + ' +')}${action('ui:zoom-out', 'Zoom out', 'minimize', mod + ' −')}${action('ui:zoom-reset', 'Reset zoom', 'monitor', mod + ' 0')}${action('ui:print', 'Print page', 'print', mod + ' P')}${action('ui:devtools', 'Developer tools', 'terminal')}<hr class="context-separator">${action('ui:extensions', 'Extensions', 'extension')}${action('ui:settings', 'Settings', 'settings')}${action('ui:shortcuts', 'Keyboard shortcuts', 'keyboard')}${action('ui:about', 'About Zacro', 'info')}</div>`,
    { title: 'Browser menu' },
  );
}
function showTabMenu(id) {
  const tab = state.tabs.find((t) => t.id === id);
  if (!tab) return;
  const action = (name, label, symbol) =>
    `<button type="button" class="context-action" data-action="${name}" data-id="${esc(id)}">${icon(symbol)}${esc(label)}</button>`;
  openDialog(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(tab.title || 'New tab')}</div>${action('ui:tab-pin', tab.pinned ? 'Unpin from favorites' : 'Pin to favorites', 'pin')}${action('ui:tab-duplicate', 'Duplicate tab', 'copy')}${action('ui:tab-split', 'Open in split view', 'split')}${action('ui:tab-move', 'Move to Space or folder', 'folder')}${action('ui:tab-rename', 'Rename tab', 'edit')}<hr class="context-separator">${action('ui:tab-close', 'Close tab', 'close')}</div>`,
    { title: 'Tab actions' },
  );
}
function showFolderMenu(id) {
  const folder = state.folders.find((f) => f.id === id);
  if (!folder) return;
  openDialog(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(folder.name)}</div><button type="button" class="context-action" data-action="ui:folder-rename" data-id="${esc(id)}">${icon('edit')}Rename folder</button><button type="button" class="context-action" data-action="ui:folder-delete" data-id="${esc(id)}">${icon('trash')}Remove folder</button></div>`,
    { title: 'Folder actions' },
  );
}
function showMoveTab(id) {
  const tab = state.tabs.find((t) => t.id === id);
  const spaces = state.spaces.filter((s) => s.profileId === tab.profileId);
  formDialog(
    'Move tab',
    'Tabs can move between Spaces in the same profile.',
    `<label class="field">Destination<select name="destination">${spaces
      .map(
        (space) =>
          `<option value="${esc(space.id)}|">${esc(space.name)} · No folder</option>${state.folders
            .filter((f) => f.spaceId === space.id)
            .map(
              (folder) =>
                `<option value="${esc(space.id)}|${esc(folder.id)}" ${tab.folderId === folder.id ? 'selected' : ''}>${esc(space.name)} / ${esc(folder.name)}</option>`,
            )
            .join('')}`,
      )
      .join('')}</select></label>`,
    'Move tab',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const [spaceId, folderId] = data.get('destination').split('|');
      await invoke('tab:move', { id, spaceId, folderId: folderId || null });
      if (!context.isCurrent()) return;
      if (!context.close()) return;
    },
  );
}
function showSplitPicker() {
  if (state.runtime?.splitTabId) {
    safely(invoke('split:toggle'));
    return;
  }
  const tabs = currentTabs().filter((t) => t.id !== state.activeTabId && t.url !== 'zacro://newtab');
  if (!tabs.length) {
    toast('Open a second page in this Space to use split view.');
    return;
  }
  openDialog(
    'split',
    `<div class="dialog-header"><h2>Room for two</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Choose a tab to place beside the current page.</p>${tabs.map((tab) => `<button type="button" class="space-option" data-action="ui:split-select" data-id="${esc(tab.id)}">${favicon(tab.url)}<span class="grow truncate">${esc(tab.title || hostname(tab.url))}</span>${icon('split')}</button>`).join('')}</div>`,
    { title: 'Choose split view tab' },
  );
}
function showTabSelection() {
  const tabs = state.tabs.filter((t) => t.profileId === activeProfile()?.id && t.url !== 'zacro://newtab');
  if (activeProfile()?.private) {
    toast('Private pages cannot be shared with AI.');
    return;
  }
  formDialog(
    'Ask selected tabs',
    'Choose up to six pages. Only the checked pages will be shared with your AI provider for your next question.',
    `<div class="tab-selector">${tabs.map((tab) => `<label class="tab-select-row"><input type="checkbox" name="tabId" value="${esc(tab.id)}" ${ui.aiTabs.includes(tab.id) ? 'checked' : ''}>${favicon(tab.url)}<span class="grow truncate" title="${esc(tab.url)}">${esc(tab.title || hostname(tab.url))}</span></label>`).join('') || '<p class="dialog-description">Open some pages first, then select the ones you want to share.</p>'}</div>`,
    'Use selected tabs',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const selected = data.getAll('tabId');
      if (selected.length > 6) throw new Error('Choose up to six tabs for one question.');
      if (ui.aiContext !== 'tabs' || JSON.stringify(ui.aiTabs) !== JSON.stringify(selected)) {
        await invoke('ai:reset');
        if (!context.isCurrent()) return;
        ui.aiMessages = [];
        ui.aiSources = [];
      }
      ui.aiTabs = selected;
      ui.aiContext = 'tabs';
      if (!context.close()) return;
      openPanel('ai');
    },
  );
}
function showPermissions() {
  const entries = profileItems('permissions');
  openDialog(
    'permissions',
    `<div class="dialog-header"><h2>Site permissions</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Permissions saved for ${esc(activeProfile()?.name)}. Clear them to ask again the next time a site requests access.</p>${entries.map((entry) => `<div class="permission-row">${icon(entry.allowed ? 'check' : 'shield')}<div class="grow">${esc(entry.origin)}<br><span class="muted">${esc(entry.permission)} · ${entry.allowed ? 'Allowed' : 'Blocked'}</span></div></div>`).join('') || '<p class="panel-intro">No saved permissions.</p>'}<div class="dialog-footer">${secondary('ui:dialog-close', 'Done')}${entries.length ? primary('ui:permissions-clear', 'Reset permissions', 'undo') : ''}</div></div>`,
    { title: 'Site permissions' },
  );
}
function showShortcuts() {
  const shortcuts = [
    ['Search or enter an address', mod + ' L'],
    ['New tab', mod + ' T'],
    ['Close current tab', mod + ' W'],
    ['Restore closed tab', mod + ' Shift T'],
    ['Ask AI / open sources', mod + ' Enter'],
    ['Find in page', mod + ' F'],
    ['Reload', mod + ' R'],
    ['History', mod + ' H'],
    ['Downloads', mod + ' J'],
    ['Bookmark page', mod + ' D'],
    ['Next tab', mod + ' Tab'],
    ['Peek link', 'Alt + click'],
    ['Dismiss Peek / dialog', 'Esc'],
  ];
  openDialog(
    'shortcuts',
    `<div class="dialog-header"><h2>Make yourself faster.</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">A few small shortcuts for a little more flow.</p><div class="shortcut-grid">${shortcuts.map(([label, key]) => `<span>${label}</span><kbd>${key}</kbd>`).join('')}</div></div>`,
    { title: 'Keyboard shortcuts' },
  );
}
function commandOptions(query) {
  const q = query.trim().toLowerCase();
  const options = [];
  if (query.trim()) {
    options.push({
      label: query.trim(),
      description: 'Navigate or search the web',
      symbol: 'search',
      type: 'Go',
      run: () => commitNavigation(query),
    });
    options.push({
      label: `Ask Zacro: ${query.trim()}`,
      description: 'Research with your AI provider',
      symbol: 'sparkle',
      type: mod + ' Enter',
      run: () => {
        closeDialog();
        askAI(query);
      },
    });
  }
  const tabs = state.tabs
    .filter(
      (t) => t.profileId === activeProfile()?.id && (!q || `${t.title} ${t.url}`.toLowerCase().includes(q)),
    )
    .slice(0, q ? 7 : 5);
  options.push(
    ...tabs.map((tab) => ({
      label: tab.title || 'New tab',
      description: `${state.spaces.find((s) => s.id === tab.spaceId)?.name} · ${hostname(tab.url)}`,
      symbol: 'globe',
      type: 'Tab',
      run: () => {
        closeDialog();
        safely(invoke('tab:activate', { id: tab.id }));
      },
    })),
  );
  if (q) {
    options.push(
      ...profileItems('bookmarks')
        .filter((b) => `${b.title} ${b.url}`.toLowerCase().includes(q))
        .slice(0, 4)
        .map((b) => ({
          label: b.title || hostname(b.url),
          description: b.url,
          symbol: 'bookmark',
          type: 'Saved',
          run: () => commitNavigation(b.url),
        })),
    );
  }
  const actions = [
    ['New tab', 'plus', () => newTab()],
    ['New Space', 'folderPlus', () => showSpaceForm()],
    [
      'History',
      'history',
      () => {
        closeDialog();
        openPanel('history');
      },
    ],
    [
      'Downloads',
      'download',
      () => {
        closeDialog();
        openPanel('downloads');
      },
    ],
    [
      'Bookmarks',
      'bookmark',
      () => {
        closeDialog();
        openPanel('bookmarks');
      },
    ],
    [
      'Archived tabs',
      'archive',
      () => {
        closeDialog();
        openPanel('archive');
      },
    ],
    [
      'Settings',
      'settings',
      () => {
        closeDialog();
        openPanel('settings');
      },
    ],
    [
      'Extensions',
      'extension',
      () => {
        closeDialog();
        openPanel('extensions');
      },
    ],
    [
      'Split view',
      'split',
      () => {
        closeDialog();
        showSplitPicker();
      },
    ],
    ['Private session', 'shield', () => newPrivate()],
    ['Keyboard shortcuts', 'keyboard', () => showShortcuts()],
  ];
  options.push(
    ...actions
      .filter(([label]) => !q || label.toLowerCase().includes(q))
      .map(([label, symbol, run]) => ({ label, description: 'Browser action', symbol, type: 'Action', run })),
  );
  return options.slice(0, 16);
}
function openCommand(mode = 'navigate', query) {
  ui.commandMode = mode;
  ui.commandQuery =
    query ??
    (mode === 'address' && (state.runtime?.peek?.url || activeTab()?.url) !== 'zacro://newtab'
      ? state.runtime?.peek?.url || activeTab()?.url || ''
      : '');
  ui.commandIndex = 0;
  openDialog(
    'command',
    `<div class="command-input-wrap">${icon('search')}<input id="command-input" type="text" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="command-results" aria-label="Search tabs, enter a URL, or ask a question" placeholder="Search, go somewhere, or ask a question…" value="${esc(ui.commandQuery)}" autocomplete="off" spellcheck="false"><kbd>Esc</kbd></div><div id="command-results" class="command-results" role="listbox" aria-label="Suggestions"></div><footer class="command-footer"><span class="row"><kbd>↑</kbd><kbd>↓</kbd> to select <kbd>Enter</kbd> to open</span><span class="row">${icon('sparkle')}<kbd>${mod} Enter</kbd> Ask Zacro</span></footer>`,
    { title: 'Command bar', focus: '#command-input' },
  );
  renderCommands();
  requestAnimationFrame(() => $('#command-input')?.select());
}
function renderCommands() {
  ui.commandItems = commandOptions(ui.commandQuery);
  ui.commandIndex = Math.max(0, Math.min(ui.commandIndex, ui.commandItems.length - 1));
  $('#command-results').innerHTML = ui.commandItems
    .map(
      (item, i) =>
        `<button type="button" class="command-result ${i === ui.commandIndex ? 'selected' : ''}" data-action="ui:command-select" data-index="${i}" role="option" tabindex="-1" aria-selected="${i === ui.commandIndex}" id="command-option-${i}"><span class="command-result-icon">${icon(item.symbol)}</span><span class="grow"><div class="command-result-label truncate">${esc(item.label)}</div><div class="command-result-description">${esc(item.description)}</div></span><span class="command-result-type">${esc(item.type)}</span></button>`,
    )
    .join('');
  $('#command-input')?.setAttribute('aria-activedescendant', `command-option-${ui.commandIndex}`);
}
async function commitNavigation(url) {
  const mode = ui.commandMode;
  closeDialog({ restore: false });
  await invoke(mode === 'newtab' ? 'tab:create' : 'navigate', { url });
}
async function newTab(command = false) {
  closeDialog({ restore: false });
  const created = await invoke('tab:create', { url: 'zacro://newtab' });
  if (created === null) return;
  if (command) openCommand('navigate');
  else
    setTimeout(() => {
      if (!ui.dialog) $('#home-query')?.focus();
    }, 40);
}
async function newPrivate() {
  closeDialog();
  const profile = await invoke('profile:create', { name: 'Private', private: true });
  if (profile?.id) {
    const fresh = await invoke('state:get');
    applyState(fresh);
    const space = state.spaces.find((s) => s.profileId === profile.id);
    if (space) await invoke('space:activate', { id: space.id });
  }
  toast('Private session opened. History and tabs won’t be saved.');
}
function openFind() {
  if (ui.dialog) closeDialog();
  if ($('#findbar').hidden) ui.findReturn = focusDescriptor();
  $('#findbar').hidden = false;
  $('#findbar').innerHTML =
    `<input id="find-input" type="text" value="${esc(ui.findText)}" placeholder="Find in page" aria-label="Find in page"><span id="find-count" class="find-count" role="status" aria-live="polite" aria-atomic="true"></span>${button('ui:find-prev', 'Previous match', 'up')}${button('ui:find-next', 'Next match', 'down')}${button('ui:find-close', 'Close find', 'close')}`;
  $('#find-input').focus();
  $('#find-input').select();
}
function closeFind() {
  safely(invoke('find:stop'));
  $('#findbar').hidden = true;
  if (!activeTab() || activeTab().url === 'zacro://newtab') restoreFocus(ui.findReturn);
  ui.findReturn = null;
}
async function askAI(question) {
  question = String(question || '').trim();
  if (!question || ui.aiBusy) return;
  closeDialog({ restore: false });
  openPanel('ai');
  const status = await invoke('ai:status');
  ui.aiStatus = status;
  if (!status?.configured) {
    renderPanel(true);
    toast('Connect an AI provider in Settings to ask Zacro.');
    return;
  }
  if (ui.aiContext === 'tabs' && !ui.aiTabs.length) {
    showTabSelection();
    return;
  }
  if (ui.aiContext === 'page' && (!activeTab() || activeTab().url === 'zacro://newtab')) {
    toast('Open a page first, or choose web research.');
    return;
  }
  ui.aiMessages.push({ role: 'user', text: question });
  ui.aiBusy = true;
  ui.aiSources = [];
  ui.aiProgress = 'Looking into it…';
  ui.aiProfileId = activeProfile()?.id;
  renderPanel(true);
  const args = { question };
  if (ui.aiContext === 'page') args.usePageContext = true;
  if (ui.aiContext === 'tabs') args.tabIds = ui.aiTabs;
  try {
    await invoke('ai:ask', args);
  } catch (error) {
    if (ui.aiBusy) {
      ui.aiBusy = false;
      ui.aiMessages.push({ role: 'assistant', text: error.message, error: true });
      renderPanel(true);
    }
  }
}
function handleEvent(event) {
  switch (event.type) {
    case 'page:backdrop':
      showPageBackdrop(event.frames);
      break;
    case 'focus:chrome':
      if (ui.dialog) $('#command-input')?.focus();
      else $('[data-key="address"]')?.focus();
      break;
    case 'auth:request':
      showAuth(event);
      break;
    case 'auth:closed':
      if (ui.authRequest === event.id) {
        ui.authRequest = null;
        closeDialog();
        if (event.reason === 'expired') toast('The sign-in request expired. Reload the page to try again.');
      }
      break;
    case 'command':
      openCommand(event.mode || 'navigate', event.query);
      break;
    case 'panel':
      openPanel(event.panel);
      break;
    case 'find':
      openFind();
      break;
    case 'find-result':
    case 'find:result': {
      const count = $('#find-count');
      if (count && ui.findText) {
        const current = event.activeMatchOrdinal || event.result?.activeMatchOrdinal || 0;
        const total = event.matches || event.result?.matches || 0;
        count.textContent = `${current}/${total}`;
        count.setAttribute('aria-label', `${current} of ${total} matches`);
      }
      break;
    }
    case 'toast':
      toast(event.message, event.error);
      break;
    case 'ai:progress':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      ui.aiBusy = true;
      ui.aiProgress = event.message || 'Looking into it…';
      if (ui.panel === 'ai') renderPanel(true);
      break;
    case 'ai:answer':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      ui.aiBusy = false;
      ui.aiProgress = '';
      ui.aiSources = event.sources || [];
      ui.aiMessages.push({
        role: 'assistant',
        text: event.answer || event.text || '',
        sources: event.sources || [],
        citations: event.citations || [],
        sharedTabs: event.sharedTabs || [],
        unreadable: event.unreadable || [],
        searchUrl: event.searchUrl,
        warning: event.warning,
        usage: event.usage,
      });
      renderPanel(true);
      requestAnimationFrame(() => {
        const c = $('#conversation');
        if (c) c.scrollTop = c.scrollHeight;
      });
      break;
    case 'ai:error':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      ui.aiBusy = false;
      ui.aiProgress = '';
      if (event.code === 'CANCELLED') {
        renderPanel(true);
        toast('Response stopped.');
        break;
      }
      ui.aiMessages.push({
        role: 'assistant',
        text: event.message || 'The request could not be completed.',
        error: true,
      });
      renderPanel(true);
      break;
    case 'ai:cancelled':
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      toast('Response stopped.');
      break;
    case 'ai:status':
      ui.aiStatus = event;
      ui.aiBusy = Boolean(event.busy);
      renderPanel(true);
      break;
    case 'ai:reset':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      break;
    case 'ai:shortcut':
      if (ui.aiSources.length && !ui.aiBusy) safely(invoke('ai:open-sources'));
      else openPanel('ai');
      break;
    case 'ai:open-sources':
      safely(invoke('ai:open-sources'));
      break;
  }
}
document.addEventListener('click', (event) => {
  const target = event.target.closest('[data-action]');
  if (!target || target.disabled) return;
  if (target.dataset.action === 'ui:backdrop' && event.target !== target) return;
  event.preventDefault();
  safely(handleAction(target.dataset.action, target.dataset, target));
});
async function handleAction(action, data = {}, target) {
  const id = data.id;
  switch (action) {
    case 'ui:panel':
      if (ui.dialog) closeDialog();
      if (ui.panel === data.panel && target?.closest('.sidebar,.toolbar')) closePanel();
      else openPanel(data.panel);
      return;
    case 'ui:panel-close':
      closePanel();
      return;
    case 'ui:address':
      openCommand('address');
      return;
    case 'ui:home-ask':
      if ($('#home-query')?.value.trim()) return askAI($('#home-query').value);
      openPanel('ai');
      return;
    case 'ui:command':
      openCommand();
      return;
    case 'ui:new-tab':
      return newTab();
    case 'ui:dialog-close':
    case 'ui:backdrop':
      dismissDialog();
      return;
    case 'ui:menu':
      showMenu();
      return;
    case 'ui:spaces':
      showSpaces();
      return;
    case 'ui:switch-space':
      closeDialog();
      return invoke('space:activate', { id });
    case 'ui:new-space':
      showSpaceForm();
      return;
    case 'ui:edit-space':
      showSpaceForm(id || state.activeSpaceId);
      return;
    case 'ui:color':
      ui.selectedColor = data.color;
      $$('.color-option').forEach((b) => {
        b.classList.toggle('selected', b.dataset.color === data.color);
        b.setAttribute('aria-pressed', b.dataset.color === data.color);
      });
      return;
    case 'ui:delete-space': {
      const s = state.spaces.find((s) => s.id === id);
      confirmDialog(
        'Delete this Space?',
        `“${s?.name}” will be removed. Its tabs will move to another Space in the same profile.`,
        () => invoke('space:delete', { id }),
        'Delete Space',
      );
      return;
    }
    case 'ui:profiles':
      showProfiles();
      return;
    case 'ui:new-profile':
      formDialog(
        'A different side of you',
        'Profiles keep accounts and browsing data separate.',
        field(
          'name',
          'Profile name',
          '',
          'text',
          'required maxlength="60" placeholder="e.g. Personal or Work"',
        ),
        'Create profile',
        async (d, context) => {
          if (!context.isCurrent()) return;
          await invoke('profile:create', { name: d.get('name') });
          if (!context.isCurrent()) return;
          applyState(await invoke('state:get'));
          if (!context.isCurrent()) return;
          if (!context.close()) return;
          showProfiles();
        },
      );
      return;
    case 'ui:new-private':
      return newPrivate();
    case 'ui:delete-profile': {
      const token = ui.dialogToken;
      await invoke('profile:delete', { id });
      if (token !== ui.dialogToken) return;
      const updated = await invoke('state:get');
      if (token !== ui.dialogToken) return;
      applyState(updated);
      closeDialog();
      showProfiles();
      return;
    }
    case 'ui:new-folder':
      formDialog(
        'Give your tabs a home',
        'Group related tabs in a folder in this Space.',
        field('name', 'Folder name', '', 'text', 'required maxlength="60"'),
        'Create folder',
        async (d, context) => {
          if (!context.isCurrent()) return;
          await invoke('folder:create', { name: d.get('name') });
          if (!context.isCurrent()) return;
          if (!context.close()) return;
        },
      );
      return;
    case 'ui:folder-toggle':
      ui.closedFolders.has(id) ? ui.closedFolders.delete(id) : ui.closedFolders.add(id);
      renderSidebar();
      return;
    case 'ui:folder-rename': {
      const folder = state.folders.find((f) => f.id === id);
      formDialog(
        'Rename folder',
        '',
        field('name', 'Folder name', folder?.name, 'text', 'required maxlength="60"'),
        'Save',
        async (d, context) => {
          if (!context.isCurrent()) return;
          await invoke('folder:update', { id, name: d.get('name') });
          if (!context.isCurrent()) return;
          if (!context.close()) return;
        },
      );
      return;
    }
    case 'ui:folder-delete':
      closeDialog();
      await invoke('folder:delete', { id });
      toast('Folder removed. Its tabs are still here.');
      return;
    case 'ui:pin-help':
      if (activeTab() && activeTab().url !== 'zacro://newtab') {
        if (!activeTab().pinned) await invoke('tab:pin', { id: state.activeTabId });
        else toast('This page is already a favorite.');
      } else toast('Open a page, then pin it to favorites.');
      return;
    case 'ui:tab-pin':
      closeDialog();
      return invoke('tab:pin', { id });
    case 'ui:tab-close':
      closeDialog();
      return invoke('tab:close', { id });
    case 'ui:tab-duplicate': {
      const tab = state.tabs.find((t) => t.id === id);
      closeDialog();
      return invoke('tab:create', { url: tab.url, spaceId: tab.spaceId });
    }
    case 'ui:tab-split':
      closeDialog();
      return invoke('split:toggle', { id });
    case 'ui:tab-move':
      showMoveTab(id);
      return;
    case 'ui:tab-rename': {
      const tab = state.tabs.find((t) => t.id === id);
      formDialog(
        'Rename tab',
        'Give this tab a name you’ll recognize.',
        field('title', 'Tab name', tab.title, 'text', 'required maxlength="200"'),
        'Rename',
        async (d, context) => {
          if (!context.isCurrent()) return;
          await invoke('tab:update', { id, title: d.get('title') });
          if (!context.isCurrent()) return;
          if (!context.close()) return;
        },
      );
      return;
    }
    case 'ui:split':
      showSplitPicker();
      return;
    case 'ui:split-select':
      closeDialog();
      return invoke('split:toggle', { id });
    case 'ui:command-select':
      ui.commandItems[Number(data.index)]?.run();
      return;
    case 'ui:open-url':
      return invoke('tab:create', { url: data.url });
    case 'ui:citation': {
      const tab = state.tabs.find((t) => t.id === id && t.profileId === activeProfile()?.id);
      if (tab) {
        await invoke('tab:activate', { id });
        if (data.pageNumber) await invoke('navigate', { url: data.url });
        else if (data.quote) await invoke('find', { text: data.quote, forward: true });
      } else await invoke('tab:create', { url: data.url });
      return;
    }
    case 'ui:history-clear':
      confirmDialog(
        'Clear this profile’s history?',
        'This removes the record of pages you visited. Your tabs, bookmarks, and other profiles stay available.',
        () => invoke('history:clear', { profileId: activeProfile()?.id }),
        'Clear history',
      );
      return;
    case 'ui:archive-clear':
      confirmDialog(
        'Empty the archive?',
        'Archived tabs in this profile will no longer be recoverable.',
        () => invoke('archive:clear', { profileId: activeProfile()?.id }),
        'Empty archive',
      );
      return;
    case 'ui:data-clear':
      return invoke('data:clear', { profileId: activeProfile()?.id });
    case 'ui:permissions':
      showPermissions();
      return;
    case 'ui:permissions-clear':
      await invoke('permission:clear', { profileId: activeProfile()?.id });
      applyState(await invoke('state:get'));
      showPermissions();
      return;
    case 'ui:extension-remove':
      confirmDialog(
        'Remove extension?',
        'The extension will be removed from this profile.',
        () => invoke('extension:remove', { id }),
        'Remove extension',
      );
      return;
    case 'ui:extensions':
      closeDialog();
      openPanel('extensions');
      return;
    case 'ui:settings':
      closeDialog();
      openPanel('settings');
      return;
    case 'app:about':
    case 'ui:about':
      return showAbout();
    case 'ui:shortcuts':
      showShortcuts();
      return;
    case 'ui:find':
      openFind();
      return;
    case 'ui:find-close':
      closeFind();
      return;
    case 'ui:find-next':
      return invoke('find', { text: ui.findText, forward: true, findNext: true });
    case 'ui:find-prev':
      return invoke('find', { text: ui.findText, forward: false, findNext: true });
    case 'ui:zoom-in':
      closeDialog();
      return invoke('zoom', { delta: 0.1 });
    case 'ui:zoom-out':
      closeDialog();
      return invoke('zoom', { delta: -0.1 });
    case 'ui:zoom-reset':
      closeDialog();
      return invoke('zoom', { reset: true });
    case 'ui:print':
      closeDialog();
      return invoke('print');
    case 'ui:devtools':
      closeDialog();
      return invoke('devtools');
    case 'ui:download-rename': {
      const file = state.downloads.find((f) => f.id === id);
      formDialog(
        'A name that makes sense',
        'The original file extension is preserved. You can undo this change.',
        field('name', 'Filename', file?.name || file?.filename, 'text', 'required maxlength="240"'),
        'Rename',
        async (d, context) => {
          if (!context.isCurrent()) return;
          await invoke('download:rename', { id, name: d.get('name') });
          if (!context.isCurrent()) return;
          if (!context.close()) return;
          toast('Download renamed. Undo is available in Downloads.');
        },
      );
      return;
    }
    case 'ui:download-suggest': {
      const file = state.downloads.find((f) => f.id === id && f.profileId === activeProfile()?.id);
      if (!file) return;
      const token = ui.dialogToken;
      const panelToken = ui.panelMotion;
      const profileId = activeProfile()?.id;
      let result = ui.downloadSuggestions.get(id);
      if (!result) {
        toast('Asking your provider for a filename suggestion…');
        result = await invoke('ai:suggest-name', {
          id,
          name: file.name || file.filename,
          url: file.url,
          title: file.sourceTitle,
        });
        if (profileId !== activeProfile()?.id) return;
        ui.downloadSuggestions.set(id, result);
      }
      if (token !== ui.dialogToken || panelToken !== ui.panelMotion) {
        toast('A filename suggestion is ready in Downloads.');
        if (ui.panel === 'downloads') renderPanel(true);
        return;
      }
      const suggestion = result?.name || result?.suggestedName || result?.filename;
      if (suggestion)
        formDialog(
          'Suggested filename',
          'Only the source URL, title, and current filename were shared. File contents were not uploaded.',
          field('name', 'Filename', suggestion, 'text', 'required maxlength="240"'),
          'Use name',
          async (d, context) => {
            if (!context.isCurrent()) return;
            await invoke('download:rename', { id, name: d.get('name') });
            ui.downloadSuggestions.delete(id);
            if (!context.isCurrent()) return;
            context.close();
          },
        );
      return;
    }
    case 'ui:ai-prompt':
      openPanel('ai');
      $('#ai-question').value = data.prompt || '';
      $('#ai-question').focus();
      return;
    case 'ui:ai-page':
      if (ui.aiContext !== 'page') {
        await invoke('ai:reset');
        ui.aiMessages = [];
        ui.aiSources = [];
      }
      ui.aiContext = 'page';
      openPanel('ai');
      return;
    case 'ui:ai-select-tabs':
      showTabSelection();
      return;
    case 'ui:ai-reset':
      await invoke('ai:reset');
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      return;
    case 'ui:ai-disconnect':
      await invoke('ai:disconnect');
      ui.aiStatus = { configured: false };
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      if (state.runtime) state.runtime.aiConfigured = false;
      ui.panelSignature = '';
      renderPanel(true);
      toast('AI provider disconnected.');
      return;
    case 'ai:cancel':
      await invoke('ai:cancel');
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      return;
    default: {
      const payload = {};
      if (id) payload.id = id;
      if (data.url) payload.url = data.url;
      if (data.title) payload.title = data.title;
      return invoke(action, payload);
    }
  }
}
document.addEventListener('submit', (event) => {
  event.preventDefault();
  const form = event.target;
  const data = new FormData(form);
  if (form.id === 'home-search') {
    const url = String(data.get('query') || '').trim();
    if (url) safely(invoke('navigate', { url }));
  } else if (form.id === 'ai-form') {
    const question = data.get('question');
    if ($('#ai-question')) $('#ai-question').value = '';
    safely(askAI(question));
  } else if (form.id === 'provider-form') {
    const panelToken = ui.panelMotion;
    const submit = $('button[type=submit]', form);
    submit.disabled = true;
    safely(
      invoke('ai:configure', {
        provider: data.get('provider'),
        apiKey: data.get('apiKey'),
        model: data.get('model'),
      })
        .then((status) => {
          ui.aiStatus =
            status?.configured !== undefined
              ? status
              : { configured: true, provider: data.get('provider'), model: data.get('model') };
          if (state.runtime) state.runtime.aiConfigured = true;
          ui.aiMessages = [];
          ui.aiSources = [];
          if (ui.panel === 'settings' && ui.panelMotion === panelToken) {
            const key = $('#api-key');
            if (key && key.value === data.get('apiKey')) key.value = '';
            const status = $('#ai-connection-status');
            if (status) status.innerHTML = '<span class="status-dot connected"></span>Provider connected';
          }
          toast('Provider connection saved.');
        })
        .finally(() => {
          submit.disabled = false;
        }),
    );
  } else if (form.id === 'modal-form' && ui.modalSubmit) {
    const submit = $('button[type=submit]', form);
    submit.disabled = true;
    const callback = ui.modalSubmit;
    const token = ui.dialogToken;
    Promise.resolve()
      .then(() => callback(data))
      .catch((error) => {
        if (token === ui.dialogToken && $('#modal-error'))
          $('#modal-error').textContent = error.message || String(error);
      })
      .finally(() => {
        if (submit.isConnected) submit.disabled = false;
      });
  }
});
document.addEventListener('input', (event) => {
  const target = event.target;
  if (target.id === 'command-input') {
    ui.commandQuery = target.value;
    ui.commandIndex = 0;
    renderCommands();
  } else if (target.id === 'panel-search') {
    ui.panelQuery = target.value;
    renderPanel();
  } else if (target.id === 'find-input') {
    ui.findText = target.value;
    if (ui.findText) safely(invoke('find', { text: ui.findText, forward: true }));
    else {
      safely(invoke('find', { text: '' }));
      const count = $('#find-count');
      if (count) {
        count.textContent = '';
        count.removeAttribute('aria-label');
      }
    }
  }
});
document.addEventListener('change', (event) => {
  const target = event.target;
  if (target.dataset.setting) {
    let value = target.type === 'checkbox' ? target.checked : target.value;
    if (['archiveAfterHours', 'openSourcesLimit', 'sidebarWidth'].includes(target.dataset.setting))
      value = Number(value);
    safely(invoke('settings:update', { values: { [target.dataset.setting]: value } }));
  } else if (target.id === 'ai-context') {
    const next = target.value;
    if (next === 'tabs') {
      showTabSelection();
    } else {
      if (ui.aiContext !== next) {
        ui.aiMessages = [];
        ui.aiSources = [];
        safely(invoke('ai:reset'));
      }
      ui.aiContext = next;
      renderPanel(true);
    }
  }
});
document.addEventListener('keydown', (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  const cmd = event.ctrlKey || event.metaKey;
  if (ui.dialog === 'command' && event.target.id === 'command-input') {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      ui.commandIndex = Math.max(
        0,
        Math.min(ui.commandItems.length - 1, ui.commandIndex + (event.key === 'ArrowDown' ? 1 : -1)),
      );
      renderCommands();
      $(`#command-option-${ui.commandIndex}`)?.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      if (cmd) {
        const question = ui.commandQuery;
        closeDialog();
        safely(askAI(question));
      } else ui.commandItems[ui.commandIndex]?.run();
      return;
    }
  }
  if (event.key === 'Escape') {
    event.preventDefault();
    if (ui.dialog) dismissDialog();
    else if (!$('#findbar').hidden) closeFind();
    else if (state?.runtime?.peek) safely(invoke('peek:close'));
    else if (ui.panel) closePanel();
    return;
  }
  if (ui.dialog && event.key === 'Tab') {
    const focusable = $$(
      'button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]',
      $('#dialog-root'),
    ).filter((el) => el.getClientRects().length && el.tabIndex >= 0);
    const first = focusable[0],
      last = focusable.at(-1);
    if (!focusable.includes(document.activeElement)) {
      event.preventDefault();
      first?.focus();
      return;
    }
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first?.focus();
    }
    return;
  }
  if (event.target.id === 'ai-question' && event.key === 'Enter' && !event.shiftKey && !cmd) {
    event.preventDefault();
    const question = event.target.value;
    event.target.value = '';
    safely(askAI(question));
    return;
  }
  if (event.target.id === 'find-input' && event.key === 'Enter') {
    event.preventDefault();
    safely(invoke('find', { text: ui.findText, forward: !event.shiftKey, findNext: true }));
    return;
  }
  if (cmd && event.key === 'Enter') {
    event.preventDefault();
    if (ui.panel === 'ai' && ui.aiSources.length && !ui.aiBusy) safely(invoke('ai:open-sources'));
    else if (event.target.id === 'home-query') safely(askAI(event.target.value));
    else if (event.target.id === 'ai-question') safely(askAI(event.target.value));
    else openPanel('ai');
    return;
  }
  if (cmd && event.key.toLowerCase() === 'l') {
    event.preventDefault();
    openCommand('address');
  } else if (cmd && event.key.toLowerCase() === 't' && !event.shiftKey) {
    event.preventDefault();
    safely(newTab(true));
  } else if (cmd && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    openFind();
  }
});
document.addEventListener('contextmenu', (event) => {
  const tab = event.target.closest('[data-tab-id]');
  const folder = event.target.closest('[data-folder-id]');
  if (tab) {
    event.preventDefault();
    showTabMenu(tab.dataset.tabId);
  } else if (folder) {
    event.preventDefault();
    showFolderMenu(folder.dataset.folderId);
  } else event.preventDefault();
});
document.addEventListener('dragstart', (event) => {
  const tab = event.target.closest('[data-tab-id]');
  if (!tab) return;
  ui.dragTab = tab.dataset.tabId;
  event.dataTransfer.effectAllowed = 'move';
  event.dataTransfer.setData('text/plain', ui.dragTab);
});
document.addEventListener('dragover', (event) => {
  const drop = event.target.closest('[data-drop-tab],[data-drop-folder]');
  if (!drop || !ui.dragTab) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'move';
  drop.classList.add('drag-over');
});
document.addEventListener('dragleave', (event) => {
  event.target.closest('[data-drop-tab],[data-drop-folder]')?.classList.remove('drag-over');
});
document.addEventListener('dragend', () => {
  ui.dragTab = null;
  $$('.drag-over').forEach((el) => el.classList.remove('drag-over'));
});
document.addEventListener('drop', (event) => {
  const drop = event.target.closest('[data-drop-tab],[data-drop-folder]');
  if (!drop || !ui.dragTab) return;
  event.preventDefault();
  const id = ui.dragTab;
  ui.dragTab = null;
  $$('.drag-over').forEach((el) => el.classList.remove('drag-over'));
  if (drop.dataset.dropTab) {
    const target = state.tabs.find((t) => t.id === drop.dataset.dropTab);
    safely(
      invoke('tab:move', {
        id,
        spaceId: target.spaceId,
        folderId: target.folderId,
        index: state.tabs.findIndex((t) => t.id === target.id),
      }),
    );
  } else
    safely(
      invoke('tab:move', { id, spaceId: state.activeSpaceId, folderId: drop.dataset.dropFolder || null }),
    );
});
function showAuth(event) {
  if (event.profileId && event.profileId !== activeProfile()?.id) {
    safely(invoke('auth:cancel', { id: event.id }));
    return;
  }
  formDialog(
    event.isProxy ? 'Proxy authentication' : 'Sign in to this site',
    `${event.origin}${event.realm ? ' · ' + event.realm : ''}`,
    field(
      'username',
      'Username',
      '',
      'text',
      'required autocomplete="off" spellcheck="false" maxlength="1000"',
    ) + field('password', 'Password', '', 'password', 'autocomplete="off" maxlength="4000"'),
    'Sign in',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const credentials = { id: event.id, username: data.get('username'), password: data.get('password') };
      ui.authRequest = null;
      if (!context.close()) return;
      await invoke('auth:respond', credentials);
    },
  );
  ui.authRequest = event.id;
}
async function showAbout() {
  const token = ui.dialogToken;
  const panelToken = ui.panelMotion;
  const profileId = activeProfile()?.id;
  const details = await invoke('app:about');
  if (token !== ui.dialogToken || panelToken !== ui.panelMotion || profileId !== activeProfile()?.id) return;
  openDialog(
    'about',
    `<div class="dialog-header">${mark}<h2>Made for the curious.</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Zacro is an independent, open-source browser by Zacro Technologies. A little more space for the web, and for you.</p><div class="shortcut-grid"><span>Zacro</span><span>${esc(details.version)}</span><span>Chromium</span><span>${esc(details.chromium)}</span><span>Electron</span><span>${esc(details.electron)}</span><span>Platform</span><span>${esc(details.platform)}</span></div><p class="provider-note">Original code is licensed under MIT. Chromium and other components retain their respective licenses. Zacro is not affiliated with The Browser Company.</p><div class="dialog-footer">${secondary('app:check-updates', 'View releases', 'external')}${primary('ui:dialog-close', 'Done')}</div></div>`,
    { title: 'About Zacro' },
  );
}
document.addEventListener('keydown', (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.defaultPrevented || !state || ui.dialog) return;
  const cmd = event.ctrlKey || event.metaKey;
  const key = event.key.toLowerCase();
  let action = null,
    payload = {};
  if (cmd && key === 't' && event.shiftKey) action = 'tab:restore';
  else if (cmd && key === 'w') {
    action = state.runtime?.peek ? 'peek:close' : 'tab:close';
    payload = { id: state.activeTabId };
  } else if (cmd && key === 'd') action = 'bookmark:toggle';
  else if (cmd && key === 'h') {
    event.preventDefault();
    openPanel('history');
    return;
  } else if (cmd && key === 'j') {
    event.preventDefault();
    openPanel('downloads');
    return;
  } else if (cmd && key === ',') {
    event.preventDefault();
    openPanel('settings');
    return;
  } else if (cmd && key === 'p') action = 'print';
  else if (cmd && key === 'r') action = 'reload';
  else if (cmd && key === 'k') {
    event.preventDefault();
    openCommand('address');
    return;
  } else if (cmd && key === 'i' && event.shiftKey) action = 'devtools';
  else if (cmd && key === 'tab') {
    event.preventDefault();
    const tabs = currentTabs();
    const current = tabs.findIndex((t) => t.id === state.activeTabId);
    const tab = tabs[(current + (event.shiftKey ? -1 : 1) + tabs.length) % tabs.length];
    if (tab) safely(invoke('tab:activate', { id: tab.id }));
    return;
  } else if (cmd && /^[1-9]$/.test(key)) {
    event.preventDefault();
    const tabs = currentTabs();
    const tab = tabs[key === '9' ? tabs.length - 1 : Number(key) - 1];
    if (tab) safely(invoke('tab:activate', { id: tab.id }));
    return;
  } else if (cmd && ['+', '=', '-', '0'].includes(key)) {
    action = 'zoom';
    payload = key === '0' ? { reset: true } : { delta: key === '-' ? -0.1 : 0.1 };
  } else if (event.altKey && key === 'arrowleft') action = 'back';
  else if (event.altKey && key === 'arrowright') action = 'forward';
  if (action) {
    event.preventDefault();
    safely(invoke(action, payload));
  }
});
document.addEventListener(
  'error',
  (event) => {
    const image = event.target;
    if (image instanceof HTMLImageElement && image.closest('.favicon'))
      image.parentElement.textContent = image.dataset.fallback || '·';
  },
  true,
);
function updateHomeClock() {
  if (!state || $('#newtab').hidden) return;
  const now = new Date();
  const time = $('.home-date .time-label');
  if (time) time.textContent = now.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  const date = $('.home-date .date-line');
  if (date)
    date.textContent = now.toLocaleDateString(undefined, {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
    });
  if (!activeProfile()?.private && $('.home-header h1'))
    $('.home-header h1').textContent =
      now.getHours() < 12 ? 'Good morning.' : now.getHours() < 18 ? 'Good afternoon.' : 'Good evening.';
}
setInterval(updateHomeClock, 30_000);
window.addEventListener('resize', syncLayout);
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (state) setTheme();
});
window.addEventListener('error', (event) => toast(`Interface error: ${event.message}`, true));
window.addEventListener('unhandledrejection', (event) => {
  event.preventDefault();
  toast(event.reason?.message || 'An operation could not be completed.', true);
});
if (window.zacro) {
  window.zacro.onState(applyState);
  window.zacro.onEvent(handleEvent);
  safely(invoke('state:get').then(applyState));
} else {
  $('#newtab').innerHTML = empty(
    'alert',
    'Launch the desktop browser',
    'Run npm start from the project directory to open Zacro with its Chromium browser engine.',
  );
}
