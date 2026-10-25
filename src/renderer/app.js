import { createSpaceGesture } from './space-gesture.js';

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
  sidebar: 'M3 4h18v16H3zM9 4v16',
  library: 'M4 4v16M9 4v16M14 4v16M18 4l3 16',
  volume: 'M4 9h4l5-5v16l-5-5H4zM16 8a6 6 0 0 1 0 8M19 5a10 10 0 0 1 0 14',
  muted: 'M4 9h4l5-5v16l-5-5H4zM17 9l5 6M22 9l-5 6',
  close: 'm6 6 12 12M18 6 6 18',
  back: 'm14 5-7 7 7 7',
  forward: 'm10 5 7 7-7 7',
  down: 'm7 10 5 5 5-5',
  up: 'm7 14 5-5 5 5',
  reload: 'M20 4v6h-6M19.1 9a7.5 7.5 0 1 0 .4 5',
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
const isMac = window.zacro?.platform === 'darwin';
// Native Mac handling owns modified Command accelerators before DOM delivery.
// Leave all other Option/Control/Shift combinations to the focused editor/OS.
const primaryModifier = (event) =>
  isMac ? event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey : event.ctrlKey;
const shortcut = (keys) => {
  const parts = keys.split('+');
  if (isMac) {
    const order = ['Ctrl', 'Alt', 'Shift', 'Mod'];
    parts.sort(
      (a, b) => (order.includes(a) ? order.indexOf(a) : 4) - (order.includes(b) ? order.indexOf(b) : 4),
    );
  }
  return parts
    .map((key) =>
      isMac
        ? { Mod: '⌘', Ctrl: '⌃', Alt: '⌥', Shift: '⇧', Enter: '↵', Left: '←', Right: '→' }[key] || key
        : key === 'Mod'
          ? 'Ctrl'
          : key,
    )
    .join(isMac ? '' : ' + ');
};
document.documentElement.dataset.platform = window.zacro?.platform || 'unknown';
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
  sidebarHidden: false,
  panelQuery: '',
  dialog: null,
  dialogReturn: null,
  commandQuery: '',
  commandIndex: 0,
  commandMode: 'navigate',
  commandItems: [],
  commandAuto: false,
  commandBusy: false,
  blankPaletteContext: null,
  shortcutQuery: '',
  recordingShortcut: null,
  shortcutError: '',
  closedFolders: new Set(),
  dragTab: null,
  aiMessages: [],
  aiBusy: false,
  aiSubmitting: false,
  aiSubmissionSerial: 0,
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
const shortcutFor = (id, fallback = '') => {
  const entry = state?.runtime?.shortcuts?.find((item) => item.id === id);
  return shortcut(entry ? entry.accelerator : fallback);
};
const shortcutLabel = (label, id, fallback = '') => {
  const key = shortcutFor(id, fallback);
  return `${label}${key ? ` (${key})` : ''}`;
};
const blankContext = () => `${state?.activeSpaceId || ''}:${state?.activeTabId || 'empty'}`;
const isBlankPage = () => !activeTab() || (activeTab().url === 'zacro://newtab' && !activeTab().homePage);
function maybeOpenBlankPalette() {
  if (!state || ui.commandBusy || !isBlankPage() || ui.dialog || ui.panel || ui.dragTab) return;
  const context = blankContext();
  if (ui.blankPaletteContext === context) return;
  ui.blankPaletteContext = context;
  requestAnimationFrame(() => {
    if (!ui.dialog && !ui.panel && !ui.commandBusy && isBlankPage() && blankContext() === context)
      openCommand('newtab', '', { automatic: true });
  });
}
const sidebarScroll = new Map();
const spaceGesture = createSpaceGesture();
let spaceGestureTimer;
let spaceGesturePending = false;
function resetSpaceFeedback() {
  const list = $('.tabs-scroll');
  if (list) {
    list.style.removeProperty('transform');
    list.style.removeProperty('opacity');
    list.classList.remove('gesture-tracking');
  }
  const preview = $('#space-gesture-preview');
  if (preview) preview.hidden = true;
}
function interruptSpaceScroll() {
  clearTimeout(spaceGestureTimer);
  spaceGesture.interrupt(performance.now());
  resetSpaceFeedback();
}
function settleSpaceGesture() {
  const result = spaceGesture.settle(performance.now());
  if (result.idleDelay) spaceGestureTimer = setTimeout(settleSpaceGesture, result.idleDelay);
  else resetSpaceFeedback();
}
function onSpaceScroll(event) {
  const sidebar = $('#sidebar');
  const spaces = state?.spaces.filter((space) => space.profileId === activeProfile()?.id) || [];
  const result = spaceGesture.update({
    deltaX: event.deltaX,
    deltaY: event.deltaY,
    deltaMode: event.deltaMode,
    shiftKey: event.shiftKey,
    ctrlKey: event.ctrlKey,
    metaKey: event.metaKey,
    altKey: event.altKey,
    buttons: event.buttons,
    defaultPrevented: event.defaultPrevented,
    momentum: typeof event.momentum === 'boolean' ? event.momentum : undefined,
    time: performance.now(),
    width: sidebar.clientWidth,
    index: spaces.findIndex((space) => space.id === state?.activeSpaceId),
    count: spaces.length,
    contextKey: activeProfile()?.id,
    blocked:
      !state ||
      ui.sidebarHidden ||
      sidebar.inert ||
      (ui.dialog && ui.dialog !== 'command') ||
      ui.dragTab ||
      spaceGesturePending ||
      Boolean(
        event.target.closest('#toolbar, .space-dots, input, textarea, select, [contenteditable="true"]'),
      ),
  });
  if (result.preventDefault) event.preventDefault();
  clearTimeout(spaceGestureTimer);
  if (result.idleDelay) spaceGestureTimer = setTimeout(settleSpaceGesture, result.idleDelay);
  if (['tracking', 'edge'].includes(result.phase)) {
    const list = $('.tabs-scroll');
    list?.classList.add('gesture-tracking');
    if (list) {
      list.style.transform = `translateX(${result.offset}px)`;
      list.style.opacity = String(1 - result.progress * 0.15);
    }
    const preview = $('#space-gesture-preview');
    const next = spaces[result.targetIndex];
    if (preview) {
      preview.hidden = !next;
      if (next)
        preview.innerHTML = `${icon(result.direction > 0 ? 'forward' : 'back')}<span>${esc(next.name)}</span>`;
    }
  } else if (result.phase !== 'committed') resetSpaceFeedback();
  if (result.commit && spaces[result.targetIndex]) {
    spaceGesturePending = true;
    const next = spaces[result.targetIndex];
    $('#live-region').textContent = `Switching to ${next.name}`;
    safely(
      invoke('space:activate', { id: next.id }).finally(() => {
        spaceGesturePending = false;
        resetSpaceFeedback();
      }),
    );
  }
}
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
  return `<span class="favicon ${data ? '' : 'favicon-placeholder'}" aria-hidden="true">${data ? `<img src="${data}" alt="" draggable="false">` : icon('globe')}</span>`;
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
const elementMotions = new WeakMap();
reducedMotion.addEventListener('change', (event) => {
  if (!event.matches) return;
  // Finish presentation immediately when the preference changes. UI state and
  // native page geometry never wait for an animation to complete.
  for (const animation of activeMotions) animation.finish();
});
function motion(element, frames, duration = 140) {
  elementMotions.get(element)?.cancel();
  if (!element || reducedMotion.matches || !element.animate) return null;
  const animation = element.animate(frames, {
    duration,
    easing: 'cubic-bezier(.16,1,.3,1)',
    fill: 'none',
  });
  activeMotions.add(animation);
  elementMotions.set(element, animation);
  const forget = () => {
    activeMotions.delete(animation);
    if (elementMotions.get(element) === animation) elementMotions.delete(element);
  };
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
  for (const selector of ['#sidebar', '#toolbar', '#captionbar', '#workspace', '#side-panel', '#findbar']) {
    const element = $(selector);
    const commandSidebar = ui.dialog === 'command' && element.closest('#sidebar');
    element.inert = active && !commandSidebar;
  }
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
  if (ui.commandAuto && ui.dialog === 'command' && !isBlankPage()) closeDialog({ restore: false });
  if (!isBlankPage()) ui.blankPaletteContext = null;
  document.documentElement.dataset.fullscreen = String(Boolean(state.runtime?.fullScreen));
  document.documentElement.dataset.focused = String(state.runtime?.focused !== false);
  setTheme();
  if (previousSpace !== state.activeSpaceId || previousTab !== state.activeTabId) clearPageBackdrop();
  if (previousProfile && previousProfile !== activeProfile()?.id) {
    if (ui.dialog === 'command') {
      ui.commandQuery = '';
      ui.commandIndex = 0;
      $('#command-input').value = '';
    }
    invalidateAIRequest();
    ui.aiMessages = [];
    ui.aiSources = [];
    ui.aiTabs = [];
    ui.aiBusy = false;
    ui.aiProgress = '';
    ui.aiContext = 'research';
    ui.aiStatus = null;
    ui.renderedAIProvider = null;
    ui.aiProviderSerial = (ui.aiProviderSerial || 0) + 1;
    ui.aiConnectionError = '';
    ui.aiConnectionMessage = '';
    ui.aiConfiguring = false;
    ui.aiSigningIn = false;
    ui.aiProfileId = activeProfile()?.id;
    ui.panelSignature = '';
    safely(invoke('ai:reset'));
    if (ui.panel === 'ai' || ui.panel === 'settings') {
      const profileId = activeProfile()?.id;
      const serial = ui.aiProviderSerial;
      safely(
        invoke('ai:status').then((status) => {
          if (profileId !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
          ui.aiStatus = status;
          renderPanel(true);
        }),
      );
    }
  }
  render();
  maybeOpenBlankPalette();
  if (previousSpace && previousSpace !== state.activeSpaceId) {
    interruptSpaceScroll();
    const spaces = state.spaces.filter((space) => space.profileId === activeProfile()?.id);
    const previousIndex = spaces.findIndex((space) => space.id === previousSpace);
    const nextIndex = spaces.findIndex((space) => space.id === state.activeSpaceId);
    const direction = previousIndex < 0 ? 1 : Math.sign(nextIndex - previousIndex);
    motion(
      $('.space-header'),
      [
        { opacity: 0.65, transform: 'translateY(2px)' },
        { opacity: 1, transform: 'translateY(0)' },
      ],
      120,
    );
    motion(
      $('.tabs-scroll'),
      [
        { opacity: 0.45, transform: `translateX(${direction * 10}px)` },
        { opacity: 1, transform: 'translateX(0)' },
      ],
      150,
    );
    motion(
      $('.newtab-inner'),
      [
        { opacity: 0.6, transform: 'translateY(4px)' },
        { opacity: 1, transform: 'translateY(0)' },
      ],
      150,
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
    renderPageMenu();
    if (ui.dialog === 'command') renderCommands({ preserve: true });
    if (ui.dialog === 'shortcuts') renderShortcutRows();
  });
  syncLayout();
}
function renderSidebar() {
  const space = activeSpace();
  const profile = activeProfile();
  const tabs = currentTabs();
  const pins = tabs.filter((t) => t.pinned);
  const loose = tabs.filter((t) => !t.pinned && !t.folderId && (t.url !== 'zacro://newtab' || t.homePage));
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
  if (ui.sidebarSpaceId) sidebarScroll.set(ui.sidebarSpaceId, $('.tabs-scroll')?.scrollTop || 0);
  for (const id of sidebarScroll.keys())
    if (!state.spaces.some((item) => item.id === id)) sidebarScroll.delete(id);
  const scroll = sidebarScroll.get(space?.id) || 0;
  const oldRows = new Map(
    $$('[data-tab-id]', $('#sidebar')).map((row) => [row.dataset.tabId, row.getBoundingClientRect().top]),
  );
  const previousActive = $('[data-tab-id].active', $('#sidebar'))?.dataset.tabId;
  const sameSpace = ui.sidebarSpaceId === space?.id;
  const tabRow = (tab) => {
    const page = state.runtime?.pages?.[tab.id];
    return `<div class="tab-row ${tab.id === state.activeTabId ? 'active' : ''}" draggable="true" data-tab-id="${esc(tab.id)}" data-drop-tab="${esc(tab.id)}"><button type="button" class="tab-main" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="tab-${esc(tab.id)}" ${tab.id === state.activeTabId ? 'aria-current="page"' : ''} title="${esc(tab.title)} — ${esc(tab.url)}">${page?.loading ? '<span class="spinner"></span>' : favicon(tab.url)}<span class="title">${esc(tab.title || 'New tab')}</span>${state.runtime?.splitTabId === tab.id ? icon('split') : ''}</button>${page?.audible || page?.muted ? button('tab:mute', page.muted ? 'Unmute tab' : 'Mute tab', page.muted ? 'muted' : 'volume', `data-id="${esc(tab.id)}"`, 'tab-audio') : ''}${button('tab:close', `Close ${tab.title || 'tab'}`, 'close', `data-id="${esc(tab.id)}" data-key="close-${esc(tab.id)}"`, 'tab-close')}</div>`;
  };
  $('#sidebar-content').innerHTML =
    `${pins.length ? `<div class="favorites" aria-label="Pinned tabs" data-drop-pinned>${pins.map((tab) => `<button type="button" class="favorite ${tab.id === state.activeTabId ? 'active' : ''}" draggable="true" data-tab-id="${esc(tab.id)}" data-drop-tab="${esc(tab.id)}" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="pin-${esc(tab.id)}" ${tab.id === state.activeTabId ? 'aria-current="page"' : ''} aria-label="${esc(tab.title || hostname(tab.url))}" title="${esc(tab.title)} — ${esc(tab.url)}">${favicon(tab.url, tab.id)}</button>`).join('')}</div>` : '<div class="favorites favorites-empty" aria-label="Pinned tabs" data-drop-pinned><span class="pin-drop-hint">Drop to pin</span></div>'}<div class="tabs-scroll">
    <div class="space-header"><button type="button" class="space-picker" data-action="ui:spaces" data-key="space-picker" aria-label="Switch Space or profile" title="${esc(space?.name)} · ${esc(profile?.name)}${profile?.private ? ' · Private session' : ''}">${profile?.private ? icon('shield') : '<span class="space-color" aria-hidden="true"></span>'}<span class="space-title">${esc(space?.name || 'My Space')}</span>${profile?.private ? '<span class="private-indicator">Private</span>' : ''}${icon('down')}</button></div>
    ${folders
      .map(
        (folder) =>
          `<div class="folder" data-folder-id="${esc(folder.id)}" data-drop-folder="${esc(folder.id)}"><button type="button" class="folder-heading" data-action="ui:folder-toggle" data-id="${esc(folder.id)}" data-key="folder-${esc(folder.id)}" aria-expanded="${!ui.closedFolders.has(folder.id)}"><span class="folder-icon">${icon('folder')}${icon('down')}</span><span class="truncate">${esc(folder.name)}</span><span class="folder-count">${tabs.filter((t) => t.folderId === folder.id).length}</span></button>${
            ui.closedFolders.has(folder.id)
              ? ''
              : `<div class="folder-tabs">${
                  tabs
                    .filter((t) => t.folderId === folder.id && !t.pinned)
                    .map(tabRow)
                    .join('') || '<div class="empty-tabs">Drop tabs here</div>'
                }</div>`
          }</div>`,
      )
      .join('')}
    <div class="loose-tabs" data-drop-folder="">${loose.map(tabRow).join('')}</div></div>
    <footer class="sidebar-footer">${button('ui:library', 'Library', 'library', 'data-key="library" aria-haspopup="dialog"')}<div class="space-dots" aria-label="Your Spaces">${spaces.map((s) => `<button type="button" class="space-dot ${s.id === space?.id ? 'active' : ''}" data-action="space:activate" data-id="${esc(s.id)}" title="${esc(s.name)}" aria-label="Switch to ${esc(s.name)}" ${s.id === space?.id ? 'aria-current="true"' : ''}><span aria-hidden="true"></span></button>`).join('')}</div>${button('ui:add-menu', 'New tab, folder or Space', 'plus', 'data-key="add-menu" aria-haspopup="dialog"')}</footer>`;
  for (const dot of $$('.space-dot')) {
    const color = spaces.find((item) => item.id === dot.dataset.id)?.color;
    if (/^#[\da-f]{6}$/i.test(color || '')) dot.style.setProperty('--dot-color', color);
  }
  $('.tabs-scroll').scrollTop = scroll;
  if (!sameSpace) $('.space-dot.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  if (sameSpace)
    for (const row of $$('[data-tab-id]', $('#sidebar'))) {
      const before = oldRows.get(row.dataset.tabId);
      if (before === undefined)
        motion(
          row,
          [
            { opacity: 0.3, transform: 'translateY(-3px) scale(.985)' },
            { opacity: 1, transform: 'translateY(0) scale(1)' },
          ],
          140,
        );
      else {
        const dy = before - row.getBoundingClientRect().top;
        if (Math.abs(dy) > 1 && Math.abs(dy) < 300)
          motion(row, [{ transform: `translateY(${dy}px)` }, { transform: 'translateY(0)' }], 140);
        else if (row.dataset.tabId === state.activeTabId && previousActive !== state.activeTabId)
          motion(row, [{ opacity: 0.7 }, { opacity: 1 }], 110);
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
    state.runtime?.fullScreen,
    ui.panel,
    ui.sidebarHidden,
    state.runtime?.shortcuts,
  ]);
  if (signature === ui.toolbarSignature) return;
  ui.toolbarSignature = signature;
  const toolbar = $('#toolbar');
  const parent = ui.sidebarHidden ? $('.main') : $('#sidebar');
  if (toolbar.parentElement !== parent) parent.prepend(toolbar);
  const controls =
    !isMac && !state.runtime?.fullScreen
      ? `<div class="window-controls">${button('window:minimize', 'Minimize', 'minimize')}${button('window:maximize', 'Maximize or restore', state.runtime?.maximized ? 'restore' : 'maximize')}${button('window:close', 'Close window', 'close', '', 'close-window')}</div>`
      : '';
  $('#captionbar').innerHTML = ui.sidebarHidden ? '' : controls;
  $('#captionbar').hidden = ui.sidebarHidden || !controls;
  $('#toolbar').innerHTML =
    `<div class="navigation">${!isMac ? `<button type="button" class="brand-button" data-action="ui:menu" data-key="browser-menu" aria-label="Browser menu" title="Zacro menu">${mark}</button>` : ''}${button('ui:sidebar-toggle', shortcutLabel(`${ui.sidebarHidden ? 'Show' : 'Hide'} sidebar`, 'sidebar-toggle', 'Mod+S'), 'sidebar', `data-key="sidebar-toggle" aria-pressed="${!ui.sidebarHidden}"`)}<span class="navigation-spacer"></span>${button('back', shortcutLabel('Back', 'history-back', isMac ? 'Mod+[' : 'Alt+Left'), 'back', `data-key="back" ${page.canGoBack ? '' : 'disabled'}`)}${button('forward', shortcutLabel('Forward', 'history-forward', isMac ? 'Mod+]' : 'Alt+Right'), 'forward', `data-key="forward" ${page.canGoForward ? '' : 'disabled'}`)}${button(page.loading ? 'stop' : 'reload', page.loading ? 'Stop loading' : shortcutLabel('Reload', 'reload', 'Mod+R'), page.loading ? 'close' : 'reload', `data-key="reload" ${blank ? 'disabled' : ''}`)}</div><div class="address-row"><button type="button" class="address-button" data-action="ui:address" data-key="address" title="${esc(tab?.url || 'Search or enter a URL')}" aria-label="Address bar: ${esc(tab?.url || 'New tab')}">${icon(blank ? 'search' : secure ? 'lock' : 'globe')}<span class="address-text">${esc(blank ? 'Search or enter URL' : ui.sidebarHidden ? displayURL(tab.url) : hostname(tab.url))}</span></button>${button('ui:page-menu', 'Page actions', 'more', 'data-key="page-menu" aria-haspopup="dialog"')}</div>${ui.sidebarHidden ? controls : ''}`;
}
function renderWorkspace() {
  const tab = activeTab();
  const blank = !tab || tab.url === 'zacro://newtab';
  const page = state.runtime?.page || {};
  $('#newtab').hidden = !(blank && tab?.homePage);
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
    ui.sidebarHidden,
  ]);
  if (tab?.homePage && signature !== ui.homeSignature) {
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
    if (!ui.peekSignature) motion($('.peek-bar'), [{ opacity: 0.55 }, { opacity: 1 }], 120);
  }
  ui.peekSignature = peekSignature;
}
function renderHome() {
  const draft = $('#home-query')?.value || '';
  const focused = document.activeElement?.id === 'home-query';
  const profile = activeProfile();
  const pins = currentTabs().filter((tab) => tab.pinned);
  const seen = new Set(ui.sidebarHidden ? [] : pins.map((tab) => tab.url));
  const links = [...(ui.sidebarHidden ? pins : []), ...profileItems('bookmarks')]
    .filter((item) => {
      if (seen.has(item.url)) return false;
      seen.add(item.url);
      return true;
    })
    .slice(0, 6);
  const recentSeen = new Set();
  const recent = profileItems('history')
    .filter((item) => {
      if (recentSeen.has(item.url)) return false;
      recentSeen.add(item.url);
      return true;
    })
    .slice(0, 3);
  $('#newtab').innerHTML =
    `<div class="newtab-inner">${profile?.private ? '<div class="private-home">' + icon('shield') + '<h1>Private browsing</h1><p>History and tabs stay in this session.</p></div>' : ''}
    <form id="home-search" class="home-search" autocomplete="off">${icon('search')}<input id="home-query" name="query" aria-label="Search the web or enter a URL" placeholder="Search or enter a URL" spellcheck="false"><button type="submit" class="icon-button" title="Go" aria-label="Go">${icon('arrow')}</button></form>
    ${links.length ? '<div class="home-links" aria-label="Saved pages">' + links.map((link) => `<button type="button" class="home-link" data-action="navigate" data-url="${esc(link.url)}" title="${esc(link.title)} — ${esc(link.url)}">${favicon(link.url)}<span class="home-link-label">${esc(link.title || hostname(link.url))}</span></button>`).join('') + '</div>' : ''}
    ${recent.length ? `<div class="home-recent"><div class="home-links-title"><h2>Recent</h2>${button('ui:panel', 'History', 'history', 'data-panel="history" data-key="home-history"', 'small-button')}</div><div class="recent-list">${recent.map((item) => `<button type="button" class="recent-page" data-action="navigate" data-url="${esc(item.url)}" title="${esc(item.url)}">${favicon(item.url)}<span class="recent-title">${esc(item.title || hostname(item.url))}</span><span class="recent-domain">${esc(hostname(item.url))}</span>${icon('arrow')}</button>`).join('')}</div></div>` : ''}</div>`;
  if (draft) $('#home-query').value = draft;
  if (focused) $('#home-query').focus({ preventScroll: true });
}

let lastLayout = '';
function syncLayout() {
  if (!state) return;
  const width = ui.sidebarHidden
    ? 0
    : Math.max(200, Math.min(380, Number(state.settings.sidebarWidth) || 224));
  const panel = ui.panel
    ? Math.min(
        Math.max(0, window.innerWidth - width - 316),
        Math.max(288, Math.min(336, window.innerWidth - width - 328)),
      )
    : 0;
  const contentTop =
    ui.sidebarHidden || !$('#findbar').hidden ? 40 : isMac || state.runtime?.fullScreen ? 8 : 36;
  $('#app').dataset.panelOpen = String(Boolean(ui.panel));
  $('#app').dataset.sidebarHidden = String(ui.sidebarHidden);
  $('#sidebar').inert = ui.sidebarHidden || Boolean(ui.dialog && ui.dialog !== 'command');
  $('#sidebar').setAttribute('aria-hidden', String(ui.sidebarHidden));
  document.documentElement.style.setProperty('--sidebar', `${width}px`);
  document.documentElement.style.setProperty('--panel', `${panel}px`);
  document.documentElement.style.setProperty('--page-top', `${contentTop}px`);
  const layout = {
    sidebarWidth: width,
    panelWidth: panel,
    contentTop,
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
  const library = ['bookmarks', 'history', 'downloads', 'archive'].includes(ui.panel);
  return `<header class="panel-header">${icon(symbol)}<h2 id="panel-title" tabindex="-1">${title}</h2>${ui.panel === 'ai' ? button('ui:ai-reset', 'New conversation', 'plus') : ''}${button('ui:panel-close', 'Close panel', 'close', 'data-key="panel-close"')}</header>${library ? `<nav class="panel-tabs" aria-label="Library sections">${['bookmarks', 'history', 'downloads', 'archive'].map((panel) => button('ui:panel', panelNames[panel][1], panelNames[panel][0], `data-panel="${panel}" data-key="panel-${panel}" aria-pressed="${ui.panel === panel}"`)).join('')}</nav>` : ''}`;
}
function patchAIContent(current, incoming) {
  // Keep the composer, native select, focused controls, and unchanged messages
  // alive while tokens arrive. Replacing this subtree interrupts IME input and
  // drops keyboard focus from the Stop button even if its value is restored.
  const key = (node) =>
    node.nodeType === Node.ELEMENT_NODE
      ? node.id ||
        node.dataset.key ||
        (node.dataset.messageIndex !== undefined ? `message-${node.dataset.messageIndex}` : '')
      : '';
  if (current.nodeType !== incoming.nodeType || current.nodeName !== incoming.nodeName) {
    current.replaceWith(incoming.cloneNode(true));
    return;
  }
  if (current.isEqualNode(incoming)) return;
  if (current.nodeType !== Node.ELEMENT_NODE) {
    current.nodeValue = incoming.nodeValue;
    return;
  }
  for (const attribute of [...current.attributes])
    if (!incoming.hasAttribute(attribute.name)) current.removeAttribute(attribute.name);
  for (const attribute of [...incoming.attributes])
    if (current.getAttribute(attribute.name) !== attribute.value)
      current.setAttribute(attribute.name, attribute.value);
  const keyed = new Map([...current.childNodes].filter(key).map((node) => [key(node), node]));
  const kept = new Set();
  [...incoming.childNodes].forEach((next, index) => {
    const nextKey = key(next);
    let existing = nextKey ? keyed.get(nextKey) : current.childNodes[index];
    if (existing && (kept.has(existing) || (!nextKey && key(existing)))) existing = null;
    if (!existing || existing.nodeType !== next.nodeType || existing.nodeName !== next.nodeName) {
      existing = next.cloneNode(true);
      current.insertBefore(existing, current.childNodes[index] || null);
    } else {
      if (existing !== current.childNodes[index])
        current.insertBefore(existing, current.childNodes[index] || null);
      patchAIContent(existing, next);
    }
    kept.add(existing);
  });
  for (const child of [...current.childNodes]) if (!kept.has(child)) child.remove();
}
function renderPanel(force = false) {
  const element = $('#side-panel');
  element.hidden = !ui.panel;
  if (!ui.panel) return;
  element.setAttribute('aria-label', panelNames[ui.panel][1]);
  const data =
    ui.panel === 'settings'
      ? [state.profiles, state.spaces, activeProfile()?.id, state.runtime?.defaultBrowser]
      : ui.panel === 'ai'
        ? [
            ui.aiMessages,
            ui.aiBusy,
            ui.aiSubmitting,
            ui.aiProgress,
            ui.aiStatus,
            ui.aiContext,
            ui.aiTabs,
            state.runtime?.aiConfigured,
            activeProfile()?.id,
          ]
        : [state[ui.panel === 'archive' ? 'archive' : ui.panel], ui.panelQuery, activeProfile()?.id];
  const signature = JSON.stringify([ui.panel, data]);
  if (!force && signature === ui.panelSignature) return;
  ui.panelSignature = signature;
  const scroll = $('.panel-body', element)?.scrollTop || 0;
  const sameAIProfile = ui.aiPanelProfile === activeProfile()?.id;
  const draft = sameAIProfile ? $('#ai-question', element)?.value : undefined;
  const disclosures = new Map(
    $$('details.setting-section', element).map((details) => [
      details.id || $('summary', details)?.textContent,
      details.open,
    ]),
  );
  const provider = ui.aiStatus?.provider || 'codex';
  const providerDraft =
    ui.renderedAIProvider === provider
      ? Object.fromEntries(
          $$(
            '#provider-form input,#provider-form select,#api-provider-form input,#api-provider-form select',
            element,
          ).map((el) => [el.id, el.value]),
        )
      : {};
  ui.renderedAIProvider = provider;
  const focused = document.activeElement;
  const focusedId = element.contains(focused) ? focused.id : null;
  const selection =
    focusedId && 'selectionStart' in focused ? [focused.selectionStart, focused.selectionEnd] : null;
  if (ui.panel === 'settings') {
    element.innerHTML = panelHeader() + `<div class="panel-body">${renderSettings()}</div>`;
  } else if (ui.panel === 'extensions') {
    element.innerHTML = panelHeader() + `<div class="panel-body">${renderExtensions()}</div>`;
  } else if (ui.panel === 'ai') {
    const html = panelHeader() + renderAI();
    if (sameAIProfile && $('#conversation', element)) {
      const next = element.cloneNode(false);
      next.innerHTML = html;
      patchAIContent(element, next);
    } else element.innerHTML = html;
    ui.aiPanelProfile = activeProfile()?.id;
  } else {
    const label = panelNames[ui.panel][1];
    element.innerHTML =
      panelHeader() +
      `<div class="panel-toolbar"><input id="panel-search" type="search" placeholder="Search ${label.toLowerCase()}" aria-label="Search ${label.toLowerCase()}" value="${esc(ui.panelQuery)}">${ui.panel === 'history' ? button('ui:history-clear', 'Clear history', 'trash') : ui.panel === 'archive' ? button('ui:archive-clear', 'Empty archive', 'trash') : ''}</div><div class="panel-body">${renderResourcePanel()}</div>`;
  }
  const body = $('.panel-body', element);
  if (body) body.scrollTop = scroll;
  const composer = $('#ai-question', element);
  if (draft !== undefined && composer && composer.value !== draft) composer.value = draft;
  for (const details of $$('details.setting-section', element)) {
    const key = details.id || $('summary', details)?.textContent;
    if (disclosures.has(key)) details.open = disclosures.get(key);
  }
  for (const [id, value] of Object.entries(providerDraft)) {
    const field = $('#' + id, element);
    if (field) field.value = value;
  }
  if (focusedId) {
    const replacement = $(`#${focusedId}`);
    if (replacement && replacement !== document.activeElement) {
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
      history: ['history', 'No history yet', 'Pages you visit appear here.'],
      bookmarks: ['bookmark', 'No bookmarks yet', 'Use the star to save a page.'],
      archive: ['archive', 'No archived tabs', 'Closed tabs will appear here.'],
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
  if (!records.length) return empty('download', 'No downloads yet', 'Files you download appear here.');
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
      return `<div class="resource"><span class="download-file">${icon('file')}</span><div class="grow"><div class="resource-title" title="${esc(name)}">${esc(name)}</div><div class="resource-meta">${esc(complete ? bytes(file.totalBytes || file.receivedBytes) : status === 'cancelled' ? 'Cancelled' : status === 'interrupted' ? 'Interrupted' : paused ? 'Paused' : `${bytes(file.receivedBytes || 0)}${file.totalBytes > 0 ? ' / ' + bytes(file.totalBytes) : ''}`)}</div>${running ? `<div class="download-progress"><progress max="100" value="${progress}" aria-label="Download progress"></progress></div>` : ''}<div class="download-operations">${complete ? `<button type="button" class="text-button" data-action="download:show" data-id="${esc(file.id)}">${isMac ? 'Show in Finder' : 'Show in folder'}</button><button type="button" class="text-button" data-action="ui:download-rename" data-id="${esc(file.id)}">Rename</button><button type="button" class="text-button" data-action="ui:download-suggest" data-id="${esc(file.id)}">${icon('sparkle')}${ui.downloadSuggestions.has(file.id) ? 'Review name' : 'Suggest name'}</button>${file.originalName || file.previousPath || file.previousName ? `<button type="button" class="text-button" data-action="download:undo" data-id="${esc(file.id)}">Undo rename</button>` : ''}` : running ? `<button type="button" class="text-button" data-action="download:${paused ? 'resume' : 'pause'}" data-id="${esc(file.id)}">${paused ? 'Resume' : 'Pause'}</button><button type="button" class="text-button danger" data-action="download:cancel" data-id="${esc(file.id)}">Cancel</button>` : ''}</div></div></div>`;
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
function aiProviderName() {
  const provider = ui.aiStatus?.provider || 'codex';
  return (
    ui.aiStatus?.providers?.find((item) => item.id === provider)?.name ||
    {
      codex: 'Codex',
      'claude-code': 'Claude Code',
      openai: 'OpenAI',
      anthropic: 'Anthropic',
      compatible: 'Custom API',
      openrouter: 'OpenRouter',
    }[provider] ||
    'AI provider'
  );
}
function isLocalAPIEndpoint(value) {
  try {
    const url = new URL(value);
    return (
      ['http:', 'https:'].includes(url.protocol) &&
      !url.username &&
      !url.password &&
      !url.search &&
      !url.hash &&
      (url.hostname === 'localhost' ||
        url.hostname === '[::1]' ||
        /^127\.(?:\d{1,3}\.){2}\d{1,3}$/.test(url.hostname))
    );
  } catch {
    return false;
  }
}
function renderAIConnection() {
  const status = ui.aiStatus || {};
  if (activeProfile()?.private) return '<p class="provider-note">AI is unavailable in private browsing.</p>';
  const provider = status.provider || 'codex';
  const providers = status.providers?.length
    ? status.providers
    : [{ id: 'codex', name: 'Codex · ChatGPT subscription', kind: 'subscription', available: true }];
  const selected = providers.find((item) => item.id === provider) || providers[0];
  const api = selected.kind === 'api';
  const connected = Boolean(status.configured ?? state.runtime?.aiConfigured);
  const pending = Boolean(status.loginPending || ui.aiSigningIn);
  const models = Array.isArray(status.models) ? status.models : [];
  const error = ui.aiConnectionError || status.error;
  const local = provider === 'compatible' && isLocalAPIEndpoint(status.baseUrl);
  const keyless = local && connected && status.credentialStorage === 'none';
  const common = `<div class="setting-field"><label for="ai-provider">Provider</label><select id="ai-provider" ${ui.aiConfiguring ? 'disabled' : ''}>${selectOptions(
    providers.map((item) => [item.id, item.name]),
    provider,
  )}</select></div><div id="ai-connection-status" class="connection-status" role="status"><span class="status-dot ${connected ? 'connected' : ''}"></span>${connected ? esc(api ? (keyless ? 'Local API ready' : 'Key saved') : status.account?.email || 'Signed in') : pending ? 'Waiting for sign-in…' : 'Not connected'}</div>${error ? `<p class="provider-note danger" role="alert">${esc(error)}</p>` : ''}${ui.aiConnectionMessage ? `<p class="provider-note" role="status">${esc(ui.aiConnectionMessage)}</p>` : ''}`;
  if (api)
    return `${common}<form id="api-provider-form" data-provider="${esc(provider)}" autocomplete="off"><label class="ai-credential-field" for="ai-api-key">API key<input id="ai-api-key" name="apiKey" type="password" autocomplete="off" spellcheck="false" placeholder="${local ? 'Optional for localhost' : connected ? 'Leave blank to keep saved key' : 'Paste an API key'}" ${connected || local ? '' : 'required'}></label>${provider === 'compatible' ? `<label class="ai-credential-field" for="ai-base-url">Base URL<input id="ai-base-url" name="baseUrl" type="url" value="${esc(status.baseUrl || '')}" placeholder="https://example.com/v1" autocomplete="off" spellcheck="false" required></label>` : ''}<label class="ai-credential-field" for="ai-api-model">Model<input id="ai-api-model" name="model" value="${esc(status.model || '')}" list="ai-model-list" placeholder="Model ID" autocomplete="off" spellcheck="false" required></label><datalist id="ai-model-list">${models.map((model) => `<option value="${esc(model.id)}">${esc(model.name || model.id)}</option>`).join('')}</datalist><div class="setting-field"><label for="ai-key-storage">Keep key</label><select id="ai-key-storage" name="storage">${selectOptions([...(status.storageAvailable ? [['encrypted', 'Encrypted on this device']] : []), ['session', 'This session only']], status.credentialStorage === 'session' || !status.storageAvailable ? 'session' : 'encrypted')}</select></div><div class="setting-actions"><button type="submit" class="primary" ${ui.aiConfiguring ? 'disabled' : ''}>Save connection</button>${connected ? secondary('ui:ai-test', 'Test connection', '', 'id="ai-test-connection"') : ''}${connected && !keyless ? secondary('ui:ai-disconnect', 'Remove key', '', 'id="ai-account-action"') : ''}</div></form><p class="provider-note">Uses your provider’s API billing.${status.credentialStorage === 'session' ? ' This key is cleared when Zacro quits.' : ''}</p>${status.storageNotice ? `<p class="provider-note">${esc(status.storageNotice)}</p>` : ''}${provider === 'compatible' ? '<p class="provider-note">Keys stay with their endpoint. Localhost can run without a key.</p>' : ''}`;
  return `${common}${connected && status.account?.planType ? `<p class="provider-note">${esc(status.account.planType)} · ${esc(aiProviderName())}</p>` : ''}${
    provider === 'codex'
      ? `<div class="setting-field"><label for="ai-auth-storage">Keep sign-in</label><select id="ai-auth-storage" ${pending || ui.aiConfiguring || status.busy ? 'disabled' : ''}>${selectOptions(
          [
            ['keyring', 'Operating system keychain'],
            ['session', 'This session only'],
          ],
          status.credentialStorage === 'session' ? 'session' : 'keyring',
        )}</select></div><p class="provider-note">Changing storage ends the current sign-in.</p>`
      : ''
  }${provider === 'claude-code' ? `<p class="provider-note">${esc(status.storageNotice || 'Claude Code manages sign-in using the macOS Keychain or its local credentials file on other systems.')}</p>` : ''}<div class="setting-actions">${connected ? secondary('ui:ai-disconnect', 'Sign out', '', 'id="ai-account-action"') : pending ? secondary('ui:ai-login-cancel', 'Cancel sign-in', '', 'id="ai-account-action"') : selected.available === false ? (provider === 'claude-code' ? primary('ai:install', 'Install Claude Code', 'external') : '<p class="provider-note">Reinstall Zacro to restore its bundled Codex runtime.</p>') : primary('ui:ai-login', provider === 'codex' ? 'Sign in with ChatGPT' : 'Sign in with Claude', 'user', 'id="ai-account-action"')}${connected ? secondary('ui:ai-test', 'Test connection', '', 'id="ai-test-connection"') : ''}</div>${provider === 'codex' && selected.available !== false && status.credentialStorage !== 'session' && !connected && !pending ? `<button type="button" class="text-button" data-action="ui:ai-session-login">Use only for this session</button>` : ''}<p class="provider-note">${provider === 'codex' ? 'Uses your Codex subscription and its usage limits. No API key required.' : 'Uses your Claude subscription through Claude Code.'}${status.credentialStorage === 'session' ? ' Sign-in is cleared when Zacro quits.' : ''}</p>${provider === 'codex' && status.storageNotice ? `<p class="provider-note">${esc(status.storageNotice)}</p>` : ''}${
    connected && models.length
      ? `<form id="provider-form" data-provider="${esc(provider)}"><div class="setting-field"><label for="ai-model">Model</label><select id="ai-model" name="model">${selectOptions(
          models.map((model) => [model.id, model.name || model.id]),
          status.model,
        )}</select></div><button type="submit" class="secondary">Use model</button></form>`
      : ''
  }`;
}
async function configureAIConnection(payload, message = 'Connection saved.') {
  const serial = (ui.aiProviderSerial = (ui.aiProviderSerial || 0) + 1);
  const profile = activeProfile()?.id;
  ui.aiConfiguring = true;
  ui.aiConnectionError = '';
  ui.aiConnectionMessage = '';
  if (payload.provider !== (ui.aiStatus?.provider || 'codex')) {
    invalidateAIRequest();
    ui.aiMessages = [];
    ui.aiSources = [];
    ui.aiBusy = false;
    ui.aiSigningIn = false;
  }
  try {
    const status = await invoke('ai:configure', payload);
    if (serial !== ui.aiProviderSerial || profile !== activeProfile()?.id) return;
    ui.aiStatus = status;
    const key = $('#ai-api-key');
    if (key) key.value = '';
    ui.aiConnectionMessage = message;
    if (state.runtime) state.runtime.aiConfigured = Boolean(status.configured);
  } catch (error) {
    if (serial === ui.aiProviderSerial && profile === activeProfile()?.id)
      ui.aiConnectionError = error.message;
  } finally {
    if (serial === ui.aiProviderSerial && profile === activeProfile()?.id) {
      ui.aiConfiguring = false;
      renderPanel(true);
    }
  }
}
function renderSettings() {
  const settings = state.settings;
  const profile = activeProfile();
  const defaultBrowser =
    isMac && state.runtime?.defaultBrowser?.supported
      ? `<div class="setting-field"><span>Default browser</span>${state.runtime.defaultBrowser.configured ? '<span class="muted">Zacro</span>' : secondary('ui:default-browser', 'Make default')}</div>`
      : '';
  return `<section class="setting-section"><h3>Appearance</h3>${defaultBrowser}${settingSelect(
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
  ])}${settingSelect('archiveAfterHours', 'Archive inactive tabs', [
    [0, 'Never'],
    [12, 'After 12 hours'],
    [24, 'After 24 hours'],
    [72, 'After 3 days'],
    [168, 'After 7 days'],
    [720, 'After 30 days'],
  ])}<p class="provider-note">Live pages stay open to protect unsaved work.</p>${settingSelect(
    'sidebarWidth',
    'Sidebar width',
    [
      [224, 'Compact'],
      [260, 'Comfortable'],
      [300, 'Spacious'],
      ...(![224, 260, 300].includes(settings.sidebarWidth)
        ? [[settings.sidebarWidth, `${settings.sidebarWidth}px`]]
        : []),
    ],
  )}<label class="setting-toggle"><span>Restore session</span><input type="checkbox" data-setting="restoreSession" ${settings.restoreSession ? 'checked' : ''}></label><div class="setting-actions">${secondary('ui:edit-space', 'Customize Space', 'edit')}${secondary('ui:profiles', 'Profiles', 'user')}${secondary('ui:shortcuts', 'Shortcuts', 'keyboard')}</div></section><details class="setting-section" id="ai-settings"><summary>AI providers</summary>${renderAIConnection()}${settingSelect(
    'openSourcesLimit',
    'Pages to open from each answer',
    [
      [1, '1 source'],
      [2, '2 sources'],
      [3, '3 sources'],
      [5, '5 sources'],
    ],
  )}<p class="provider-note">Page sharing is off by default. Choose “Current page” or select tabs in the conversation to share page or PDF text for a question. Password and form fields are excluded. Scanned and encrypted PDFs cannot be read.</p></details><details class="setting-section"><summary>Your data</summary><p class="panel-intro"><strong>${esc(profile?.name)}</strong> profile</p><div class="setting-actions">${secondary('data:export', 'Export data', 'external')}${secondary('data:import', 'Import data', 'download')}</div><p class="provider-note">Zacro backups and bookmark HTML. Private sessions and sign-in credentials are excluded.</p><div class="setting-actions">${secondary('ui:data-clear', 'Clear browsing data', 'trash')}${secondary('ui:permissions', 'Site permissions', 'shield')}</div></details><details class="setting-section"><summary>Extensions</summary><p class="panel-intro">Load compatible unpacked extensions into this profile. Supported APIs vary; Chrome Web Store installation and extension sync are not available.</p>${secondary('ui:panel', 'Manage extensions', 'extension', 'data-panel="extensions"')}</details><details class="setting-section"><summary>About Zacro</summary><p class="panel-intro">An independent, open-source browser.<br>Version ${esc(state.runtime?.version || '0.1.0')} · Built on Chromium</p><div class="setting-actions">${secondary('app:about', 'Version details', 'info')}${secondary('ui:shortcuts', 'Shortcuts', 'keyboard')}</div></details>`;
}
function renderExtensions() {
  const extensions = profileItems('extensions');
  return `<p class="panel-intro">Extensions are isolated to <strong>${esc(activeProfile()?.name)}</strong>. Install only extensions you trust and review their requested access.</p>${primary('extension:install', 'Load unpacked extension', 'plus')}<p class="provider-note">Select a local folder containing manifest.json. Electron supports a subset of Chrome extension APIs; storage.sync and Web Store installation are unavailable.</p>${extensions.length ? extensions.map((ext) => `<article class="extension-card"><div class="row"><div class="extension-icon">${icon('extension')}</div><div class="grow"><h3>${esc(ext.name || ext.id)}</h3><span class="small muted">${esc(ext.version || '')} · ${ext.enabled === false ? 'Disabled' : 'Enabled'}</span></div></div>${ext.description ? `<p>${esc(ext.description)}</p>` : ''}${ext.error ? `<p class="danger">${esc(ext.error)}</p>` : ''}<div class="row between"><button type="button" class="text-button" data-action="extension:toggle" data-id="${esc(ext.id)}">${ext.enabled === false ? 'Enable' : 'Disable'}</button><button type="button" class="text-button danger" data-action="ui:extension-remove" data-id="${esc(ext.id)}">Remove</button></div></article>`).join('') : empty('extension', 'No extensions', 'Installed extensions appear here.')}`;
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
    body = `<div class="ai-welcome">${icon('sparkle')}<h3>${privateSession ? 'Private session' : configured ? 'Ask Zacro' : 'AI, your way'}</h3><p>${privateSession ? 'AI is unavailable in private browsing.' : configured ? 'Ask a question or bring in a page.' : 'Connect a subscription or API provider in Settings.'}</p>${configured ? `<button type="button" class="prompt-suggestion" data-action="ui:ai-page">Ask about this page${icon('arrow')}</button><button type="button" class="prompt-suggestion" data-action="ui:ai-select-tabs">Compare tabs${icon('arrow')}</button>` : privateSession ? primary('ui:spaces', 'Switch profile', 'user') : primary('ui:ai-connect', 'Connect AI', 'user')}</div>`;
  } else {
    body = messages
      .map(
        (message, index) =>
          `<article class="message ${message.role}" data-message-index="${index}"><div class="message-role">${message.role === 'user' ? 'You' : message.error ? 'Something went wrong' : 'Zacro'}</div><div class="message-content ${message.error ? 'danger' : ''}">${message.role === 'assistant' ? renderAnswer(message) : esc(message.text)}</div>${message.warning ? `<p class="provider-note danger">${esc(message.warning)}</p>` : ''}${message.sharedTabs?.length ? `<p class="provider-note">Shared: ${esc(message.sharedTabs.map((t) => t.title || t.url || t).join(', '))}</p>` : ''}${message.unreadable?.length ? `<p class="provider-note">Couldn’t read: ${esc(message.unreadable.map((t) => t.title || t.url || t.reason || t).join(', '))}</p>` : ''}${message.sources?.length ? `<div class="source-list">${message.sources.map((source, i) => `<button type="button" class="source-item" data-action="ui:open-url" data-url="${esc(source.url)}" title="${esc(source.url)}"><span class="source-index">${i + 1}</span><span class="grow truncate">${esc(source.title || hostname(source.url))}</span>${icon('external')}</button>`).join('')}</div>` : ''}${message.searchUrl ? `<button type="button" class="text-button" data-action="ui:open-url" data-url="${esc(message.searchUrl)}">${icon('search')}Open ordinary search results</button>` : ''}</article>`,
      )
      .join('');
  }
  return `<div class="panel-body conversation" id="conversation">${body}${ui.aiBusy ? `<div class="ai-progress" role="status"><span class="spinner"></span>${esc(ui.aiProgress || 'Looking into it…')}</div>` : ''}</div>${
    configured
      ? `<div class="ai-footer" id="ai-footer">${ui.aiSources.length && !ui.aiBusy ? `<button type="button" class="secondary ai-source-action" id="ai-open-sources" data-action="ai:open-sources">${icon('external')}Open sources <kbd>${shortcut('Mod+Enter')}</kbd></button>` : ''}<div class="ai-context" id="ai-context-controls">${icon('shield')}<label for="ai-context" class="sr-only">Content to share</label><select id="ai-context" ${activeProfile()?.private ? 'disabled' : ''}>${selectOptions(
          [
            [
              'research',
              ui.aiStatus?.researchSupported === false
                ? 'Chat · no page sharing'
                : 'Web research · no page sharing',
            ],
            ['page', 'Current page'],
            ['tabs', `Selected tabs${ui.aiTabs.length ? ' (' + ui.aiTabs.length + ')' : ''}`],
          ],
          ui.aiContext,
        )}</select>${ui.aiContext === 'tabs' ? button('ui:ai-select-tabs', 'Choose tabs', 'plus', '', 'small-button') : ''}</div>${
          ui.aiContext !== 'research'
            ? `<p class="provider-note" id="ai-sharing">Sharing with ${esc(aiProviderName())}: ${esc(
                ui.aiContext === 'page'
                  ? activeTab()?.title || 'Current page'
                  : state.tabs
                      .filter((t) => ui.aiTabs.includes(t.id))
                      .map((t) => t.title)
                      .join(', ') || 'No tabs selected',
              )}</p>`
            : ''
        }<form id="ai-form" class="ai-composer"><textarea id="ai-question" name="question" rows="2" placeholder="${configured ? 'Ask anything…' : 'Connect a provider in Settings'}" aria-label="Ask Zacro" ${configured ? '' : 'disabled'}></textarea>${ui.aiBusy ? button('ai:cancel', 'Stop response', 'stop', 'id="ai-submit"') : '<button type="submit" class="primary" id="ai-submit" aria-label="Send question" ' + (configured && !ui.aiSubmitting ? '' : 'disabled') + '>' + icon('arrow') + '</button>'}</form><p class="ai-help" id="ai-help">${activeProfile()?.private ? 'AI is unavailable in private sessions.' : 'Check sources. Shift + Enter for a new line.'}</p></div>`
      : !privateSession && messages.length
        ? `<div class="ai-footer" id="ai-footer">${primary('ui:ai-connect', ui.aiStatus?.loginPending || ui.aiSigningIn ? 'Continue sign-in' : 'Connect AI', 'user', 'id="ai-reconnect"')}</div>`
        : ''
  }`;
}
function openPanel(panel, { refreshStatus = true } = {}) {
  if (!panelNames[panel]) return;
  if (ui.dialog) closeDialog();
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
        { opacity: 0.65, transform: 'translateX(6px)' },
        { opacity: 1, transform: 'translateX(0)' },
      ],
      140,
    );
  const profileId = activeProfile()?.id;
  const providerSerial = ui.aiProviderSerial;
  if (refreshStatus && (panel === 'ai' || panel === 'settings'))
    safely(
      invoke('ai:status').then((status) => {
        if (profileId !== activeProfile()?.id || providerSerial !== ui.aiProviderSerial) return;
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
  ui.panelMotion = (ui.panelMotion || 0) + 1;
  $('#side-panel')
    .getAnimations()
    .forEach((animation) => animation.cancel());
  const focus = ui.panelReturn;
  ui.panel = null;
  ui.panelSignature = '';
  ui.panelReturn = null;
  render();
  restoreFocus(focus);
  maybeOpenBlankPalette();
}
function openDialog(kind, html, { title, focus } = {}) {
  stopShortcutRecording();
  if (kind !== 'command') interruptSpaceScroll();
  if (ui.authRequest) {
    const id = ui.authRequest;
    ui.authRequest = null;
    safely(invoke('auth:cancel', { id }));
  }
  ui.dialogReturn =
    ui.dialog && $('#dialog-root').contains(document.activeElement) ? ui.dialogReturn : focusDescriptor();
  ui.dialogToken = (ui.dialogToken || 0) + 1;
  ui.dialog = kind;
  $('#dialog-root').innerHTML =
    `<div class="dialog-backdrop ${kind === 'command' ? 'command-backdrop' : ''}" data-action="ui:backdrop"><section class="dialog ${kind === 'command' ? 'command-dialog' : kind === 'menu' ? 'context-menu' : kind === 'library' ? 'library-dialog' : ''}" role="dialog" aria-modal="${kind !== 'command'}" aria-label="${esc(title || kind)}" tabindex="-1">${html}</section></div>`;
  isolateDialog(true);
  syncLayout();
  const focusToken = ui.dialogToken;
  requestAnimationFrame(() => {
    const root = $('#dialog-root');
    // A fast keyboard/pointer action may already have chosen a control before
    // the first painted frame. Initial focus must not overwrite that choice.
    if (ui.dialogToken === focusToken && !root.contains(document.activeElement))
      (
        $(
          focus ||
            'input:not(:disabled), select:not(:disabled), button:not(:disabled), textarea:not(:disabled)',
          root,
        ) || $('.dialog', root)
      )?.focus();
  });
}
function closeDialog({ restore = true } = {}) {
  stopShortcutRecording();
  if (ui.authRequest) {
    const id = ui.authRequest;
    ui.authRequest = null;
    safely(invoke('auth:cancel', { id }));
  }
  const focus = ui.dialogReturn;
  ui.dialog = null;
  ui.commandAuto = false;
  ui.modalSubmit = null;
  ui.dialogToken = (ui.dialogToken || 0) + 1;
  $('#dialog-root').replaceChildren();
  clearPageBackdrop();
  isolateDialog(false);
  syncLayout();
  if (restore) restoreFocus(focus);
  ui.dialogReturn = null;
  maybeOpenBlankPalette();
}
function openPopover(kind, html, { title, anchor } = {}) {
  const rect = (anchor || document.activeElement)?.getBoundingClientRect?.();
  openDialog(kind, html, { title });
  const backdrop = $('.dialog-backdrop');
  const dialog = $('.dialog', backdrop);
  backdrop.classList.add('popover-backdrop');
  dialog.classList.add('popover-panel');
  const bounds = dialog.getBoundingClientRect();
  const edge = 8;
  const left = Math.max(edge, Math.min(rect?.left || edge, innerWidth - bounds.width - edge));
  let top = (rect?.bottom || 36) + 5;
  if (top + bounds.height > innerHeight - edge) top = (rect?.top || innerHeight) - bounds.height - 5;
  dialog.style.left = `${left}px`;
  dialog.style.top = `${Math.max(edge, Math.min(top, innerHeight - bounds.height - edge))}px`;
}
function dismissDialog() {
  if (!ui.dialog) return;
  // Closing returns the live document and keyboard focus in this turn. An
  // outro would otherwise hold the native page behind its captured backdrop.
  closeDialog();
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
  openPopover(
    'spaces',
    `<div class="dialog-header"><h2>Your Spaces</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body">${state.spaces
      .map((space) => {
        const profile = state.profiles.find((p) => p.id === space.profileId);
        return `<div class="space-option-wrapper"><button type="button" class="space-option ${space.id === state.activeSpaceId ? 'current' : ''}" data-action="ui:switch-space" data-id="${esc(space.id)}"><span class="space-emblem">${esc(space.name.slice(0, 1).toUpperCase())}</span><span class="grow"><div class="space-option-name">${esc(space.name)}</div><div class="space-option-profile">${esc(profile?.name)}${profile?.private ? ' · Private' : ''} · ${state.tabs.filter((t) => t.spaceId === space.id).length} tabs</div></span>${space.id === state.activeSpaceId ? icon('check') : ''}</button><div class="space-option-actions">${button('ui:edit-space', 'Edit Space', 'edit', `data-id="${esc(space.id)}"`)}${button('ui:delete-space', 'Delete Space', 'trash', `data-id="${esc(space.id)}"`)}</div></div>`;
      })
      .join(
        '',
      )}<div class="space-manager-actions">${primary('ui:new-space', 'New Space', 'plus')}${secondary('ui:profiles', 'Manage profiles', 'user')}</div></div>`,
    { title: 'Your Spaces', anchor: $('[data-key="space-picker"]') },
  );
}
function showSpaceForm(id) {
  const space = id ? state.spaces.find((s) => s.id === id) : null;
  ui.selectedColor = space?.color || colors[0][1];
  formDialog(
    space ? 'Customize Space' : 'New Space',
    '',
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
  openPopover(
    'menu',
    `<div class="dialog-body">${action('ui:new-tab', 'New tab', 'plus', shortcutFor('command-palette', 'Mod+T'))}${action('ui:new-private', 'New private session', 'shield')}${action('ui:spaces', 'Spaces & profiles', 'user')}<hr class="context-separator">${action('ui:find', 'Find on page', 'search', shortcutFor('find', 'Mod+F'))}${action('ui:zoom-in', 'Zoom in', 'plus', shortcut('Mod+='))}${action('ui:zoom-out', 'Zoom out', 'minimize', shortcut('Mod+−'))}${action('ui:zoom-reset', 'Reset zoom', 'monitor', shortcut('Mod+0'))}${action('ui:print', 'Print page', 'print', shortcutFor('print', 'Mod+P'))}${action('ui:devtools', 'Developer tools', 'terminal')}<hr class="context-separator">${action('ui:extensions', 'Extensions', 'extension')}${action('ui:settings', 'Settings', 'settings')}${action('ui:shortcuts', 'Keyboard shortcuts', 'keyboard')}${action('ui:home-page', 'Home page', 'monitor')}${action('ui:about', 'About Zacro', 'info')}</div>`,
    { title: 'Browser menu', anchor: $('[data-key="browser-menu"]') },
  );
}
function showAddMenu() {
  const action = (name, label, symbol, key = '') =>
    `<button type="button" class="context-action" data-action="${name}">${icon(symbol)}<span>${label}</span>${key ? `<kbd>${key}</kbd>` : ''}</button>`;
  openPopover(
    'menu',
    `<div class="dialog-body">${action('ui:new-tab', 'New tab', 'plus', shortcutFor('command-palette', 'Mod+T'))}${action('ui:new-folder', 'New folder', 'folderPlus')}${action('ui:new-space', 'New Space', 'layers')}<hr class="context-separator">${action('ui:new-private', 'Private session', 'shield')}</div>`,
    { title: 'Add', anchor: $('[data-key="add-menu"]') },
  );
}
function showPageMenu() {
  const tab = state.runtime?.peek || activeTab();
  const blank = !tab || tab.url === 'zacro://newtab';
  const saved = profileItems('bookmarks').some((item) => item.url === tab?.url);
  const action = (name, label, symbol, attrs = '', key = '') =>
    `<button type="button" class="context-action" data-action="${name}" ${attrs}>${icon(symbol)}<span>${label}</span>${key ? `<kbd>${key}</kbd>` : ''}</button>`;
  openPopover(
    'page-actions',
    `<div class="dialog-body">${action('ui:bookmark', saved ? 'Remove bookmark' : 'Bookmark this page', 'star', `data-key="bookmark" aria-pressed="${saved}" ${blank ? 'disabled' : ''}`, shortcutFor('bookmark', 'Mod+D'))}${action('ui:split', state.runtime?.splitTabId ? 'Close split view' : 'Split view', 'split', 'data-key="split"')}${action('ui:find', 'Find on page', 'search', blank ? 'disabled' : '', shortcutFor('find', 'Mod+F'))}${action('ui:print', 'Print page', 'print', blank ? 'disabled' : '', shortcutFor('print', 'Mod+P'))}<hr class="context-separator"><div class="menu-zoom" aria-label="Page zoom">${button('ui:zoom-out', 'Zoom out', 'minimize')}${action('ui:zoom-reset', `${Math.round((state.runtime?.page?.zoom || 1) * 100)}%`, 'monitor')}${button('ui:zoom-in', 'Zoom in', 'plus')}</div></div>`,
    { title: 'Page actions', anchor: $('[data-key="page-menu"]') },
  );
}
function renderPageMenu() {
  if (ui.dialog !== 'page-actions') return;
  const root = $('.popover-panel');
  if (!root) return;
  const tab = state.runtime?.peek || activeTab();
  const blank = !tab || tab.url === 'zacro://newtab';
  const saved = profileItems('bookmarks').some((item) => item.url === tab?.url);
  const bookmark = $('[data-key="bookmark"]', root);
  bookmark.disabled = blank;
  bookmark.setAttribute('aria-pressed', String(saved));
  $('span', bookmark).textContent = saved ? 'Remove bookmark' : 'Bookmark this page';
  $('[data-key="split"] span', root).textContent = state.runtime?.splitTabId
    ? 'Close split view'
    : 'Split view';
  for (const action of ['ui:find', 'ui:print']) $(`[data-action="${action}"]`, root).disabled = blank;
  $('[data-action="ui:zoom-reset"] span', root).textContent =
    `${Math.round((state.runtime?.page?.zoom || 1) * 100)}%`;
}
function showLibrary() {
  openPopover(
    'library',
    `<div class="dialog-body">${['bookmarks', 'history', 'downloads', 'archive'].map((panel) => `<button type="button" class="context-action" data-action="ui:panel" data-panel="${panel}" data-key="panel-${panel}">${icon(panelNames[panel][0])}<span>${panelNames[panel][1]}</span>${panel === 'history' ? `<kbd>${shortcutFor('history', isMac ? 'Mod+Y' : 'Mod+H')}</kbd>` : panel === 'downloads' ? `<kbd>${shortcutFor('downloads', isMac ? 'Mod+Shift+J' : 'Mod+J')}</kbd>` : ''}</button>`).join('')}<hr class="context-separator">${['ai', 'settings'].map((panel) => `<button type="button" class="context-action" data-action="ui:panel" data-panel="${panel}" data-key="panel-${panel}">${icon(panelNames[panel][0])}<span>${panelNames[panel][1]}</span>${panel === 'settings' ? `<kbd>${shortcutFor('preferences', 'Mod+,')}</kbd>` : ''}</button>`).join('')}<hr class="context-separator"><button type="button" class="context-action" data-action="ui:home-page">${icon('monitor')}<span>Home page</span></button></div>`,
    { title: 'Library', anchor: $('[data-key="library"]') },
  );
}
function toggleSidebar(fromPage = false) {
  interruptSpaceScroll();
  if (ui.dialog) closeDialog({ restore: false });
  ui.sidebarHidden = !ui.sidebarHidden;
  render();
  if (!ui.sidebarHidden)
    motion(
      $('#sidebar'),
      [
        { opacity: 0.65, transform: 'translateX(-4px)' },
        { opacity: 1, transform: 'translateX(0)' },
      ],
      140,
    );
  if (fromPage) safely(invoke('page:focus'));
  else $('[data-key="sidebar-toggle"]')?.focus({ preventScroll: true });
}
function showTabMenu(id) {
  const tab = state.tabs.find((t) => t.id === id);
  if (!tab) return;
  const action = (name, label, symbol) =>
    `<button type="button" class="context-action" data-action="${name}" data-id="${esc(id)}">${icon(symbol)}${esc(label)}</button>`;
  openPopover(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(tab.title || 'New tab')}</div>${action('ui:tab-pin', tab.pinned ? 'Unpin from favorites' : 'Pin to favorites', 'pin')}${action('ui:tab-duplicate', 'Duplicate tab', 'copy')}${action('ui:tab-split', 'Open in split view', 'split')}${action('ui:tab-move', 'Move to Space or folder', 'folder')}${action('ui:tab-rename', 'Rename tab', 'edit')}<hr class="context-separator">${action('ui:tab-close', 'Close tab', 'close')}</div>`,
    { title: 'Tab actions', anchor: $(`[data-tab-id="${CSS.escape(id)}"]`) },
  );
}
function showFolderMenu(id) {
  const folder = state.folders.find((f) => f.id === id);
  if (!folder) return;
  openPopover(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(folder.name)}</div><button type="button" class="context-action" data-action="ui:folder-rename" data-id="${esc(id)}">${icon('edit')}Rename folder</button><button type="button" class="context-action" data-action="ui:folder-delete" data-id="${esc(id)}">${icon('trash')}Remove folder</button></div>`,
    { title: 'Folder actions', anchor: $(`[data-key="folder-${CSS.escape(id)}"]`) },
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
    `Choose up to six pages. Only the checked pages will be shared with ${aiProviderName()} for your next question.`,
    `<div class="tab-selector">${tabs.map((tab) => `<label class="tab-select-row"><input type="checkbox" name="tabId" value="${esc(tab.id)}" ${ui.aiTabs.includes(tab.id) ? 'checked' : ''}>${favicon(tab.url)}<span class="grow truncate" title="${esc(tab.url)}">${esc(tab.title || hostname(tab.url))}</span></label>`).join('') || '<p class="dialog-description">Open some pages first, then select the ones you want to share.</p>'}</div>`,
    'Use selected tabs',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const selected = data.getAll('tabId');
      if (selected.length > 6) throw new Error('Choose up to six tabs for one question.');
      if (ui.aiContext !== 'tabs' || JSON.stringify(ui.aiTabs) !== JSON.stringify(selected)) {
        invalidateAIRequest();
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
function stopShortcutRecording() {
  if (!ui.recordingShortcut) return;
  ui.recordingShortcut = null;
  safely(invoke('shortcut:record', { active: false }));
}
function showShortcuts() {
  ui.shortcutQuery = '';
  ui.shortcutError = '';
  openDialog(
    'shortcuts',
    `<div class="dialog-header"><h2>Keyboard shortcuts</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="shortcut-search-wrap">${icon('search')}<input id="shortcut-search" type="search" aria-label="Search shortcuts" placeholder="Find a shortcut" autocomplete="off"></div><div id="shortcut-rows" class="shortcut-rows"></div><div id="shortcut-status" class="shortcut-status" role="status" aria-live="polite"></div><footer class="shortcut-footer"><span>Click a shortcut to change it</span><button type="button" class="text-button" data-action="ui:shortcut-reset-all">Reset all</button></footer>`,
    { title: 'Keyboard shortcuts', focus: '#shortcut-search' },
  );
  $('.dialog').classList.add('shortcut-dialog');
  renderShortcutRows();
}
function renderShortcutRows() {
  const root = $('#shortcut-rows');
  if (!root) return;
  const selected = document.activeElement?.dataset?.shortcutRecord;
  const q = ui.shortcutQuery.trim().toLowerCase();
  let category = '';
  root.innerHTML =
    (state.runtime?.shortcuts || [])
      .filter((entry) => `${entry.label} ${entry.category} ${entry.accelerator}`.toLowerCase().includes(q))
      .map((entry) => {
        const heading =
          entry.category !== category ? `<div class="shortcut-category">${esc(entry.category)}</div>` : '';
        category = entry.category;
        const recording = ui.recordingShortcut === entry.id;
        return `${heading}<div class="shortcut-row" data-shortcut-id="${esc(entry.id)}"><span class="grow">${esc(entry.label)}</span><button type="button" class="shortcut-key ${recording ? 'recording' : ''}" data-action="ui:shortcut-record" data-id="${esc(entry.id)}" data-shortcut-record="${esc(entry.id)}" aria-label="${esc(`Change shortcut for ${entry.label}`)}" title="${esc(entry.defaultAccelerator ? `Default: ${shortcut(entry.defaultAccelerator)}` : 'No default shortcut')}" ${entry.editable === false ? 'disabled' : ''}><kbd>${recording ? 'Press keys…' : esc(entry.accelerator ? shortcut(entry.accelerator) : 'Unassigned')}</kbd></button>${button('ui:shortcut-reset', `Reset ${entry.label}`, 'undo', `data-id="${esc(entry.id)}" data-shortcut-reset="${esc(entry.id)}" ${entry.customized ? '' : 'disabled'}`)}</div>`;
      })
      .join('') || '<div class="command-empty">No shortcuts found</div>';
  const status = $('#shortcut-status');
  status.textContent =
    ui.shortcutError || (ui.recordingShortcut ? 'Press a combination. Esc cancels; Delete removes it.' : '');
  status.classList.toggle('danger', Boolean(ui.shortcutError));
  if (selected) $(`[data-shortcut-record="${CSS.escape(selected)}"]`, root)?.focus({ preventScroll: true });
}
async function recordShortcut(id) {
  stopShortcutRecording();
  ui.recordingShortcut = id;
  ui.shortcutError = '';
  renderShortcutRows();
  $(`[data-shortcut-record="${CSS.escape(id)}"]`)?.focus();
  try {
    await invoke('shortcut:record', { active: true });
    if (ui.recordingShortcut !== id || ui.dialog !== 'shortcuts')
      await invoke('shortcut:record', { active: false });
  } catch (error) {
    stopShortcutRecording();
    ui.shortcutError = error.message;
    renderShortcutRows();
  }
}
function recordedAccelerator(event) {
  const keys = [];
  if (isMac ? event.metaKey : event.ctrlKey) keys.push('Mod');
  if (isMac && event.ctrlKey) keys.push('Ctrl');
  if (!isMac && event.metaKey) keys.push('Meta');
  if (event.altKey) keys.push('Alt');
  if (event.shiftKey) keys.push('Shift');
  const physical = /^Key[A-Z]$/.test(event.code)
    ? event.code.slice(3)
    : /^Digit\d$/.test(event.code)
      ? event.code.slice(5)
      : {
          Equal: '=',
          Minus: '-',
          BracketLeft: '[',
          BracketRight: ']',
          Comma: ',',
          Period: '.',
          Slash: '/',
          Backslash: '\\',
          Semicolon: ';',
          Quote: "'",
          Backquote: '`',
        }[event.code];
  const key =
    physical ||
    { ArrowLeft: 'Left', ArrowRight: 'Right', ArrowUp: 'Up', ArrowDown: 'Down', ' ': 'Space', '+': '=' }[
      event.key
    ] ||
    event.key;
  if (
    !isMac &&
    event.ctrlKey &&
    event.altKey &&
    (event.getModifierState('AltGraph') ||
      (event.key.length === 1 && physical && event.key.toUpperCase() !== physical.toUpperCase()))
  )
    return null;
  if (['Control', 'Meta', 'Alt', 'Shift', 'Dead', 'Unidentified'].includes(key)) return null;
  return [...keys, key.length === 1 && /[a-z]/i.test(key) ? key.toUpperCase() : key].join('+');
}
async function saveShortcut(id, accelerator) {
  stopShortcutRecording();
  try {
    await invoke('shortcut:set', { id, accelerator });
    const next = await invoke('state:get');
    applyState(next);
    ui.shortcutError = '';
  } catch (error) {
    ui.shortcutError = error.message || 'That shortcut cannot be used.';
  }
  if (ui.dialog === 'shortcuts') {
    renderShortcutRows();
    $(`[data-shortcut-record="${CSS.escape(id)}"]`)?.focus({ preventScroll: true });
  }
}
const commandSymbols = {
  'command-palette': 'plus',
  'open-location': 'search',
  'sidebar-toggle': 'sidebar',
  'save-page': 'download',
  'reopen-tab': 'undo',
  'next-tab': 'forward',
  'previous-tab': 'back',
  'next-space': 'layers',
  'previous-space': 'layers',
  bookmark: 'bookmark',
  'pin-tab': 'pin',
  'duplicate-tab': 'copy',
  'rename-tab': 'edit',
  'move-tab': 'folder',
  'mute-tab': 'volume',
  'new-folder': 'folderPlus',
  'new-space': 'layers',
  'new-private-space': 'shield',
  preferences: 'settings',
  shortcuts: 'keyboard',
  history: 'history',
  downloads: 'download',
  bookmarks: 'bookmark',
  archive: 'archive',
  extensions: 'extension',
  ai: 'sparkle',
  find: 'search',
  'find-next': 'down',
  'find-previous': 'up',
  reload: 'reload',
  'force-reload': 'reload',
  stop: 'stop',
  'history-back': 'back',
  'history-forward': 'forward',
  'zoom-in': 'plus',
  'zoom-out': 'minimize',
  'zoom-reset': 'monitor',
  split: 'split',
  'peek-close': 'close',
  'peek-promote': 'external',
  'copy-url': 'copy',
  print: 'print',
  fullscreen: 'maximize',
  'developer-tools': 'terminal',
};
const commandAliases = {
  preferences: 'settings appearance theme search engine sidebar width',
  'command-palette': 'new tab search open',
  'new-space': 'create workspace',
  'new-private-space': 'incognito private browsing',
  shortcuts: 'keyboard keybindings hotkeys edit',
  ai: 'ask zacro assistant codex chatgpt',
  split: 'split view compare side by side',
  bookmarks: 'saved favorites library',
  archive: 'closed tabs restore',
  'save-page': 'save as html download page',
  'copy-url': 'copy link address',
};
function commandActionOptions() {
  const tab = activeTab();
  const real = tab && tab.url !== 'zacro://newtab';
  const needsPage = new Set([
    'save-page',
    'bookmark',
    'pin-tab',
    'duplicate-tab',
    'rename-tab',
    'move-tab',
    'mute-tab',
    'find',
    'find-next',
    'find-previous',
    'reload',
    'force-reload',
    'copy-url',
    'print',
  ]);
  const catalog = state.runtime?.shortcuts || [];
  return catalog
    .filter((entry) => commandSymbols[entry.id])
    .filter((entry) => !needsPage.has(entry.id) || real)
    .filter((entry) => !entry.id.startsWith('peek-') || state.runtime?.peek)
    .filter((entry) => entry.id !== 'stop' || state.runtime?.page?.loading)
    .filter((entry) => entry.id !== 'history-back' || state.runtime?.page?.canGoBack)
    .filter((entry) => entry.id !== 'history-forward' || state.runtime?.page?.canGoForward)
    .map((entry) => ({
      id: `action:${entry.id}`,
      kind: 'action',
      label: entry.id === 'command-palette' ? 'New tab' : entry.label,
      description: '',
      symbol: commandSymbols[entry.id],
      type: entry.accelerator ? shortcut(entry.accelerator) : 'Action',
      keywords: `${entry.category} ${entry.id.replaceAll('-', ' ')} ${commandAliases[entry.id] || ''}`,
      priority: 4,
      run: () => {
        closeDialog({ restore: false });
        return invoke('shortcut:run', { id: entry.id });
      },
    }));
}
function fuzzyScore(query, value) {
  const normalize = (text) =>
    String(text || '')
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
  const q = normalize(query),
    text = normalize(value);
  if (!q) return 0;
  if (text === q) return 160;
  if (text.startsWith(q)) return 125 - Math.min(15, (text.length - q.length) / 8);
  const at = text.indexOf(q);
  if (at >= 0) return (at === 0 || /[\s./:_-]/.test(text[at - 1]) ? 105 : 82) - Math.min(20, at / 3);
  const words = q.split(/\s+/).filter(Boolean);
  let total = 0;
  for (const word of words) {
    let cursor = 0,
      previous = -2,
      score = 0;
    for (const char of word) {
      const found = text.indexOf(char, cursor);
      if (found < 0) return -1;
      score += found === previous + 1 ? 9 : found === 0 || /[\s./:_-]/.test(text[found - 1]) ? 8 : 2;
      score -= Math.min(5, (found - cursor) / 5);
      previous = found;
      cursor = found + 1;
    }
    total += Math.min(70, 35 + score - (text.length - word.length) / 12);
  }
  return total / words.length;
}
function commandOptions(query) {
  const raw = query.trim();
  const actionsOnly = raw.startsWith('>') || raw.startsWith('/');
  const q = (actionsOnly ? raw.slice(1) : raw).trim();
  const options = [];
  const add = (item) => {
    const score = q
      ? Math.max(
          fuzzyScore(q, item.label),
          fuzzyScore(q, item.description) * 0.75,
          fuzzyScore(q, item.keywords) * 0.7,
        )
      : 0;
    if (q && score < 20) return;
    options.push({ ...item, score: score + (item.priority || 0) });
  };
  if (!actionsOnly) {
    const tabs = state.tabs.filter(
      (tab) => tab.profileId === activeProfile()?.id && (tab.url !== 'zacro://newtab' || tab.homePage),
    );
    tabs.sort((a, b) => (b.lastActiveAt || 0) - (a.lastActiveAt || 0));
    for (const [index, tab] of tabs.entries()) {
      if (!q && (tab.id === state.activeTabId || index > 5)) continue;
      add({
        id: `tab:${tab.id}`,
        kind: 'tab',
        label: tab.title || hostname(tab.url),
        description:
          tab.spaceId === state.activeSpaceId
            ? hostname(tab.url)
            : state.spaces.find((space) => space.id === tab.spaceId)?.name,
        keywords: tab.url,
        url: tab.url,
        symbol: 'globe',
        type: 'Switch to tab',
        priority: q ? 14 : 100 - index,
        run: () => {
          closeDialog({ restore: false });
          return invoke('tab:activate', { id: tab.id });
        },
      });
    }
    const seen = new Set(options.filter((item) => item.kind === 'tab').map((item) => item.url));
    for (const [kind, items] of [
      ['bookmark', profileItems('bookmarks')],
      ['history', profileItems('history')],
    ]) {
      for (const [index, item] of items.entries()) {
        if (seen.has(item.url) || item.url === 'zacro://newtab') continue;
        if (!q && index > 2) continue;
        const before = options.length;
        add({
          id: `${kind}:${item.url}`,
          kind,
          label: item.title || hostname(item.url),
          description: displayURL(item.url),
          url: item.url,
          symbol: kind === 'bookmark' ? 'bookmark' : 'history',
          type: kind === 'bookmark' ? 'Bookmark' : 'History',
          priority: q ? (kind === 'bookmark' ? 8 : 0) : 60 - index,
          run: () => {
            const existing = tabs.find((tab) => tab.url === item.url);
            if (existing) {
              closeDialog({ restore: false });
              return invoke('tab:activate', { id: existing.id });
            }
            return commitNavigation(item.url);
          },
        });
        if (options.length > before) seen.add(item.url);
      }
    }
    for (const space of state.spaces.filter(
      (item) => item.profileId === activeProfile()?.id && item.id !== state.activeSpaceId,
    ))
      add({
        id: `space:${space.id}`,
        kind: 'space',
        label: space.name,
        description: '',
        keywords: 'switch space workspace',
        symbol: 'layers',
        type: 'Space',
        priority: q ? 9 : 30,
        run: () => {
          closeDialog({ restore: false });
          return invoke('space:activate', { id: space.id });
        },
      });
  }
  for (const option of commandActionOptions()) {
    if (
      !q &&
      !actionsOnly &&
      !['action:new-folder', 'action:new-space', 'action:preferences', 'action:shortcuts'].includes(option.id)
    )
      continue;
    add({ ...option, priority: q ? option.priority : 20 });
  }
  if (q && !actionsOnly) {
    const address =
      /^(?:[a-z][a-z\d+.-]*:\/\/|localhost(?::\d+)?(?:[/?#]|$)|(?:[\w-]+\.)+[a-z]{2,}(?:[:/?#]|$)|(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?:[/?#]|$))/i.test(
        q,
      );
    options.push({
      id: 'navigation',
      kind: 'navigation',
      label: q,
      description: '',
      symbol: address ? 'globe' : 'search',
      type: address
        ? ui.commandMode === 'address'
          ? 'Go to address'
          : 'Open page'
        : `Search ${{ duckduckgo: 'DuckDuckGo', google: 'Google', bing: 'Bing', brave: 'Brave' }[state.settings.searchEngine] || 'the web'}`,
      score: address ? 220 : 45,
      url: q,
      run: () => commitNavigation(q),
    });
    if (!activeProfile()?.private && (ui.aiStatus?.configured ?? state.runtime?.aiConfigured))
      options.push({
        id: 'ask',
        kind: 'action',
        label: `Ask Zacro: ${q}`,
        description: '',
        symbol: 'sparkle',
        type: shortcutFor('ai', 'Mod+Enter'),
        score: 10,
        run: () => {
          closeDialog();
          return askAI(q);
        },
      });
  }
  return options.sort((a, b) => b.score - a.score).slice(0, actionsOnly ? 80 : q ? 16 : 8);
}
function openCommand(mode = 'newtab', query, { automatic = false } = {}) {
  ui.commandMode = mode === 'address' || mode === 'navigate' ? 'address' : 'newtab';
  ui.commandAuto = automatic;
  if (isBlankPage()) ui.blankPaletteContext = blankContext();
  ui.commandQuery =
    query ??
    (mode === 'address' && (state.runtime?.peek?.url || activeTab()?.url) !== 'zacro://newtab'
      ? state.runtime?.peek?.url || activeTab()?.url || ''
      : '');
  ui.commandIndex = 0;
  openDialog(
    'command',
    `<div class="command-input-wrap">${icon('search')}<input id="command-input" type="text" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="command-results" aria-label="Search tabs, history, Spaces and actions, or enter a URL" placeholder="Search or enter a URL" value="${esc(ui.commandQuery)}" autocomplete="off" spellcheck="false"><button type="button" class="command-mode" data-action="ui:command-mode" aria-label="Change navigation destination"></button></div><div id="command-results" class="command-results" role="listbox" aria-label="Suggestions"></div><footer class="command-footer"><span><kbd>↑↓</kbd> Select <kbd>↵</kbd> Open</span><span><kbd>Alt ↵</kbd> New tab <kbd>/</kbd> Actions</span></footer>`,
    { title: 'Command bar', focus: '#command-input' },
  );
  renderCommands();
  const token = ui.dialogToken;
  requestAnimationFrame(() => {
    if (ui.dialog === 'command' && ui.dialogToken === token) $('#command-input')?.select();
  });
}
function renderCommands({ preserve = false } = {}) {
  const root = $('#command-results');
  if (!root) return;
  const selected = preserve ? ui.commandItems[ui.commandIndex]?.id : null;
  ui.commandItems = commandOptions(ui.commandQuery);
  if (selected && ui.commandItems.some((item) => item.id === selected))
    ui.commandIndex = ui.commandItems.findIndex((item) => item.id === selected);
  ui.commandIndex = Math.max(0, Math.min(ui.commandIndex, ui.commandItems.length - 1));
  root.innerHTML =
    ui.commandItems
      .map(
        (item, index) =>
          `<button type="button" class="command-result ${index === ui.commandIndex ? 'selected' : ''}" data-action="ui:command-select" data-index="${index}" data-command-id="${esc(item.id)}" data-command-kind="${item.kind}" role="option" tabindex="-1" aria-selected="${index === ui.commandIndex}" id="command-option-${index}"><span class="command-result-icon">${item.url && item.kind !== 'navigation' ? favicon(item.url) : icon(item.symbol)}</span><span class="grow command-result-copy"><span class="command-result-label truncate">${esc(item.label)}</span>${item.description ? `<span class="command-result-description">${esc(item.description)}</span>` : ''}</span><span class="command-result-type">${esc(item.type)}</span></button>`,
      )
      .join('') || '<div class="command-empty" role="presentation">No matching actions</div>';
  const input = $('#command-input');
  if (ui.commandItems.length)
    input?.setAttribute('aria-activedescendant', `command-option-${ui.commandIndex}`);
  else input?.removeAttribute('aria-activedescendant');
  const mode = $('.command-mode');
  mode.textContent = ui.commandMode === 'address' ? 'This tab' : 'New tab';
  mode.setAttribute(
    'aria-label',
    `Destination: ${ui.commandMode === 'address' ? 'current tab' : 'new tab'}. Change destination`,
  );
}
function selectCommand(index, { separate = false } = {}) {
  const item = ui.commandItems[index];
  if (!item || ui.commandBusy) return;
  if (separate && item.url && item.url !== 'zacro://newtab') return safely(commitNavigation(item.url, true));
  safely(Promise.resolve().then(() => item.run()));
}
async function commitNavigation(url, separate = false) {
  if (ui.commandBusy || !String(url || '').trim()) return;
  const mode = ui.commandMode;
  ui.commandBusy = true;
  ui.commandAuto = false;
  closeDialog({ restore: false });
  try {
    const reuse = !separate && (!activeTab() || activeTab().url === 'zacro://newtab');
    await invoke((mode === 'newtab' || separate) && !reuse ? 'tab:create' : 'navigate', { url });
    applyState(await invoke('state:get'));
  } catch (error) {
    openCommand(mode, url);
    throw error;
  } finally {
    ui.commandBusy = false;
  }
}
function newTab() {
  openCommand('newtab', '');
}
async function showHomePage() {
  ui.commandBusy = true;
  closeDialog({ restore: false });
  try {
    await invoke('tab:create', { url: 'zacro://newtab', homePage: true });
    applyState(await invoke('state:get'));
  } finally {
    ui.commandBusy = false;
  }
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
  syncLayout();
}
function closeFind() {
  safely(invoke('find:stop'));
  $('#findbar').hidden = true;
  syncLayout();
  if (!activeTab() || activeTab().url === 'zacro://newtab') restoreFocus(ui.findReturn);
  ui.findReturn = null;
}
function cancelAIStreamFrame() {
  if (ui.aiStreamFrame) cancelAnimationFrame(ui.aiStreamFrame);
  ui.aiStreamFrame = null;
}
function invalidateAIRequest() {
  ui.aiSubmissionSerial++;
  ui.aiSubmitting = false;
  cancelAIStreamFrame();
}
function shouldFollowAI() {
  const body = $('#conversation');
  return !body || body.scrollHeight - body.scrollTop - body.clientHeight < 80;
}
function renderAIUpdate(follow = shouldFollowAI()) {
  renderPanel(true);
  const body = $('#conversation');
  if (ui.panel === 'ai' && follow && body) body.scrollTop = body.scrollHeight;
}
async function askAI(question) {
  question = String(question || '').trim();
  if (!question || ui.aiBusy || ui.aiSubmitting) return false;
  const serial = ++ui.aiSubmissionSerial;
  const context = {
    profileId: activeProfile()?.id,
    kind: ui.aiContext,
    tabId: activeTab()?.id,
    tabUrl: activeTab()?.url,
    tabIds: [...ui.aiTabs],
  };
  const current = () => serial === ui.aiSubmissionSerial && context.profileId === activeProfile()?.id;
  ui.aiSubmitting = true;
  closeDialog({ restore: false });
  openPanel('ai', { refreshStatus: false });
  try {
    const status = await invoke('ai:status');
    if (!current()) return false;
    if (
      context.kind !== ui.aiContext ||
      (context.kind === 'page' &&
        (context.tabId !== activeTab()?.id || context.tabUrl !== activeTab()?.url)) ||
      (context.kind === 'tabs' && JSON.stringify(context.tabIds) !== JSON.stringify(ui.aiTabs))
    ) {
      toast('The browsing context changed. Send your question again.');
      return false;
    }
    ui.aiStatus = status;
    if (!status?.configured || activeProfile()?.private) {
      toast(
        activeProfile()?.private
          ? 'AI is unavailable in private browsing.'
          : 'Connect an AI provider in Settings to ask Zacro.',
      );
      return false;
    }
    if (context.kind === 'tabs' && !context.tabIds.length) {
      showTabSelection();
      return false;
    }
    if (context.kind === 'page' && (!context.tabId || context.tabUrl === 'zacro://newtab')) {
      toast('Open a page first, or choose web research.');
      return false;
    }
    const composer = $('#ai-question');
    if (composer?.value.trim() === question) composer.value = '';
    ui.aiMessages.push({ role: 'user', text: question });
    ui.aiBusy = true;
    ui.aiSubmitting = false;
    ui.aiSources = [];
    ui.aiProgress = 'Looking into it…';
    ui.aiProfileId = context.profileId;
    renderAIUpdate(true);
    const args = { question };
    if (context.kind === 'page') args.tabIds = [context.tabId];
    if (context.kind === 'tabs') args.tabIds = context.tabIds;
    try {
      await invoke('ai:ask', args);
    } catch (error) {
      if (current() && ui.aiBusy) {
        ui.aiBusy = false;
        ui.aiMessages.push({ role: 'assistant', text: error.message, error: true });
        renderAIUpdate();
      }
    }
    return true;
  } finally {
    if (current()) {
      ui.aiSubmitting = false;
      renderPanel(true);
    }
  }
}

function handleEvent(event) {
  switch (event.type) {
    case 'newtab:show':
      closeDialog({ restore: false });
      safely(invoke('state:get').then(applyState));
      break;
    case 'shortcut': {
      const action = {
        shortcuts: 'ui:shortcuts',
        split: 'ui:split',
        'rename-tab': 'ui:tab-rename',
        'move-tab': 'ui:tab-move',
        'new-space': 'ui:new-space',
        'new-folder': 'ui:new-folder',
        'find-next': 'ui:find-next',
        'find-previous': 'ui:find-prev',
      }[event.id];
      if (action) {
        if (ui.dialog) closeDialog();
        if (['find-next', 'find-previous'].includes(event.id) && $('#findbar').hidden) openFind();
        else safely(handleAction(action, { id: state.activeTabId }));
      }
      break;
    }
    case 'sidebar:toggle':
      toggleSidebar(event.fromPage === true);
      break;
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
      if (ui.panel === 'ai') renderAIUpdate();
      break;
    case 'ai:delta': {
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      let message = ui.aiMessages.at(-1);
      if (!message?.streaming) {
        message = { role: 'assistant', text: '', streaming: true };
        ui.aiMessages.push(message);
      }
      message.text += event.delta || '';
      ui.aiBusy = true;
      ui.aiProgress = 'Writing…';
      if (!ui.aiStreamFrame)
        ui.aiStreamFrame = requestAnimationFrame(() => {
          ui.aiStreamFrame = null;
          if (ui.panel !== 'ai') return;
          renderAIUpdate();
        });
      break;
    }
    case 'ai:answer': {
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      const follow = shouldFollowAI();
      cancelAIStreamFrame();
      ui.aiBusy = false;
      ui.aiProgress = '';
      ui.aiSources = event.sources || [];
      if (ui.aiMessages.at(-1)?.streaming) ui.aiMessages.pop();
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
      renderAIUpdate(follow);
      break;
    }
    case 'ai:error':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      cancelAIStreamFrame();
      ui.aiBusy = false;
      ui.aiProgress = '';
      if (ui.aiMessages.at(-1)?.streaming) {
        ui.aiMessages.at(-1).streaming = false;
        ui.aiMessages.at(-1).warning = 'Response incomplete.';
      }
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
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      cancelAIStreamFrame();
      ui.aiBusy = false;
      ui.aiProgress = '';
      if (ui.aiMessages.at(-1)?.streaming) {
        ui.aiMessages.at(-1).streaming = false;
        ui.aiMessages.at(-1).warning = 'Response stopped.';
      }
      renderPanel(true);
      toast('Response stopped.');
      break;
    case 'ai:status':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      ui.aiStatus = event;
      if (state.runtime) state.runtime.aiConfigured = Boolean(event.configured);
      ui.aiBusy = Boolean(event.busy);
      renderPanel(true);
      break;
    case 'ai:reset':
      if (event.profileId && event.profileId !== activeProfile()?.id) break;
      invalidateAIRequest();
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      break;
    case 'ai:shortcut':
      if (ui.dialog === 'command' && ui.commandQuery.trim()) safely(askAI(ui.commandQuery));
      else if (document.activeElement?.id === 'ai-question' && $('#ai-question').value.trim())
        safely(askAI($('#ai-question').value));
      else if (document.activeElement?.id === 'home-query' && $('#home-query').value.trim())
        safely(askAI($('#home-query').value));
      else if (ui.aiSources.length && !ui.aiBusy) safely(invoke('ai:open-sources'));
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
  if (target.dataset.action === 'ui:command-select') {
    selectCommand(Number(target.dataset.index), { separate: event.altKey });
    return;
  }
  safely(handleAction(target.dataset.action, target.dataset, target));
});
async function handleAction(action, data = {}, target) {
  const id = data.id;
  if (ui.dialog === 'command' && action === 'tab:activate') closeDialog({ restore: false });
  switch (action) {
    case 'ui:ai-test': {
      const profileId = activeProfile()?.id;
      const provider = ui.aiStatus?.provider;
      target.disabled = true;
      ui.aiConnectionError = '';
      ui.aiConnectionMessage = '';
      try {
        const result = await invoke('ai:test-connection');
        if (profileId !== activeProfile()?.id || provider !== ui.aiStatus?.provider) return;
        if (Array.isArray(result.models)) ui.aiStatus.models = result.models;
        const message = [result.message, result.warning].filter(Boolean).join(' ');
        if (result.ok) ui.aiConnectionMessage = message || 'Connection verified.';
        else ui.aiConnectionError = message || 'The connection could not be verified.';
      } catch (error) {
        if (profileId === activeProfile()?.id && provider === ui.aiStatus?.provider)
          ui.aiConnectionError = error.message;
      } finally {
        if (target.isConnected) target.disabled = false;
        renderPanel(true);
      }
      return;
    }
    case 'ui:ai-session-login':
      await configureAIConnection(
        { provider: 'codex', authStorage: 'session' },
        'Sign-in will last for this session only.',
      );
      if (!ui.aiConnectionError) return handleAction('ui:ai-login', {}, target);
      return;
    case 'ui:home-page':
      return showHomePage();
    case 'ui:command-mode':
      ui.commandMode = ui.commandMode === 'address' ? 'newtab' : 'address';
      renderCommands({ preserve: true });
      $('#command-input')?.focus();
      return;
    case 'ui:shortcut-record':
      return recordShortcut(id);
    case 'ui:shortcut-reset':
    case 'ui:shortcut-reset-all':
      stopShortcutRecording();
      await invoke('shortcut:reset', action === 'ui:shortcut-reset' ? { id } : {});
      ui.shortcutError = '';
      applyState(await invoke('state:get'));
      return;
    case 'ui:default-browser': {
      target.disabled = true;
      try {
        const status = await invoke('app:set-default-browser');
        if (state.runtime) state.runtime.defaultBrowser = status;
        renderPanel(true);
        toast(
          status.configured
            ? 'Zacro is your default browser.'
            : 'Confirm Zacro as your default browser in macOS.',
        );
      } finally {
        if (target.isConnected) target.disabled = false;
      }
      return;
    }
    case 'ui:sidebar-toggle':
      toggleSidebar();
      return;
    case 'ui:library':
      showLibrary();
      return;
    case 'ui:add-menu':
      showAddMenu();
      return;
    case 'ui:page-menu':
      showPageMenu();
      return;
    case 'ui:bookmark': {
      const tab = state.runtime?.peek || activeTab();
      closeDialog();
      return invoke('bookmark:toggle', { url: tab?.url, title: tab?.title });
    }
    case 'ui:ai-connect':
      if (ui.dialog) closeDialog();
      openPanel('settings');
      if ($('#ai-settings')) {
        $('#ai-settings').open = true;
        $('#ai-settings').scrollIntoView({ block: 'start' });
        $('#ai-settings [data-action="ui:ai-login"]')?.focus({ preventScroll: true });
      }
      return;
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
        'New profile',
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
        'New folder',
        '',
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
    case 'ui:folder-toggle': {
      const opening = ui.closedFolders.has(id);
      opening ? ui.closedFolders.delete(id) : ui.closedFolders.add(id);
      restoreFocusAround(renderSidebar);
      const heading = $$('.folder-heading').find((element) => element.dataset.id === id);
      motion(
        heading?.querySelector('.folder-icon > svg:last-child'),
        [{ transform: `rotate(${opening ? -90 : 0}deg)` }, { transform: `rotate(${opening ? 0 : -90}deg)` }],
        120,
      );
      return;
    }
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
      if (ui.dialog) closeDialog();
      showSplitPicker();
      return;
    case 'ui:split-select':
      closeDialog();
      return invoke('split:toggle', { id });
    case 'ui:command-select':
      selectCommand(Number(data.index));
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
        toast(`Asking ${aiProviderName()} for a filename suggestion…`);
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
        invalidateAIRequest();
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
      invalidateAIRequest();
      await invoke('ai:reset');
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      return;
    case 'ui:ai-login':
      if (ui.aiSigningIn || ui.aiStatus?.loginPending) return;
      ui.aiSigningIn = true;
      renderPanel(true);
      {
        const profileId = activeProfile()?.id;
        const serial = ui.aiProviderSerial;
        try {
          const status = await invoke('ai:login');
          if (profileId !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
          ui.aiStatus = status;
          ui.aiConnectionError = '';
        } catch (error) {
          if (profileId !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
          const status = await invoke('ai:status').catch(() => ui.aiStatus);
          if (profileId !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
          ui.aiStatus = status;
          ui.aiConnectionError = error.message;
        } finally {
          if (profileId === activeProfile()?.id && serial === ui.aiProviderSerial) {
            ui.aiSigningIn = false;
            renderPanel(true);
          }
        }
      }
      return;
    case 'ui:ai-login-cancel':
      ui.aiStatus = await invoke('ai:login-cancel');
      ui.aiSigningIn = false;
      renderPanel(true);
      return;
    case 'ui:ai-disconnect':
      invalidateAIRequest();
      await invoke('ai:disconnect');
      ui.aiStatus = await invoke('ai:status');
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      if (state.runtime) state.runtime.aiConfigured = false;
      ui.panelSignature = '';
      renderPanel(true);
      toast('Disconnected AI provider.');
      return;
    case 'ai:cancel':
      invalidateAIRequest();
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
    safely(askAI(question));
  } else if (form.id === 'provider-form' || form.id === 'api-provider-form') {
    const submit = $('button[type=submit]', form);
    submit.disabled = true;
    const payload = {
      provider: form.dataset.provider || ui.aiStatus?.provider || 'codex',
      model: String(data.get('model') || '').trim(),
    };
    if (form.id === 'api-provider-form') {
      const key = String(data.get('apiKey') || '').trim();
      if (key) payload.apiKey = key;
      if (data.has('baseUrl')) payload.baseUrl = String(data.get('baseUrl') || '').trim();
      payload.storage = data.get('storage');
    }
    safely(
      configureAIConnection(
        payload,
        form.id === 'provider-form' ? 'Model updated.' : 'Connection saved.',
      ).finally(() => {
        if (submit.isConnected) submit.disabled = false;
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
  } else if (target.id === 'shortcut-search') {
    ui.shortcutQuery = target.value;
    renderShortcutRows();
  } else if (target.id === 'ai-base-url') {
    const key = $('#ai-api-key');
    const changed = target.value.trim() !== (ui.aiStatus?.baseUrl || '');
    if (key) {
      const local = isLocalAPIEndpoint(target.value.trim());
      key.required = !local && (changed || !ui.aiStatus?.configured);
      key.placeholder = local
        ? 'Optional for localhost'
        : changed
          ? 'New key required for this endpoint'
          : ui.aiStatus?.configured
            ? 'Leave blank to keep saved key'
            : 'Paste an API key';
    }
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
  } else if (target.id === 'ai-auth-storage') {
    target.disabled = true;
    safely(
      configureAIConnection(
        { provider: 'codex', authStorage: target.value },
        target.value === 'session'
          ? 'Sign in again for this session only.'
          : 'Sign in again using the operating system keychain.',
      ),
    );
  } else if (target.id === 'ai-provider') {
    target.disabled = true;
    safely(
      configureAIConnection({ provider: target.value }, '').finally(() => {
        if (target.isConnected) target.disabled = false;
      }),
    );
  } else if (target.id === 'ai-context') {
    const next = target.value;
    if (next === 'tabs') {
      showTabSelection();
    } else {
      if (ui.aiContext !== next) {
        invalidateAIRequest();
        ui.aiMessages = [];
        ui.aiSources = [];
        safely(invoke('ai:reset'));
      }
      ui.aiContext = next;
      renderPanel(true);
    }
  }
});
document.addEventListener(
  'keydown',
  (event) => {
    if (!ui.recordingShortcut || event.isComposing) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.repeat) return;
    if (event.key === 'Escape') {
      stopShortcutRecording();
      renderShortcutRows();
      return;
    }
    const id = ui.recordingShortcut;
    if (
      ['Backspace', 'Delete'].includes(event.key) &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey &&
      !event.shiftKey
    ) {
      safely(saveShortcut(id, ''));
      return;
    }
    const accelerator = recordedAccelerator(event);
    if (accelerator) safely(saveShortcut(id, accelerator));
  },
  true,
);
document.addEventListener('keydown', (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  const cmd = primaryModifier(event);
  if (ui.dialog === 'command' && event.target.id === 'command-input') {
    if (event.key === 'Tab' && !event.shiftKey && ['', '/', '>'].includes(ui.commandQuery.trim())) {
      event.preventDefault();
      ui.commandQuery = ui.commandQuery.trim() ? '' : '/';
      $('#command-input').value = ui.commandQuery;
      ui.commandIndex = 0;
      renderCommands();
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      ui.commandIndex =
        (ui.commandIndex + (event.key === 'ArrowDown' ? 1 : -1) + ui.commandItems.length) %
        Math.max(1, ui.commandItems.length);
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
      } else selectCommand(ui.commandIndex, { separate: event.altKey });
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
  const popover = ui.dialog && $('.popover-panel');
  if (popover && ['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    const items = $$('button:not(:disabled)', popover).filter((item) => item.getClientRects().length);
    if (items.length) {
      event.preventDefault();
      const focused = items.indexOf(document.activeElement);
      const current = focused < 0 && event.key === 'ArrowUp' ? 0 : focused;
      const next =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? items.length - 1
            : (current + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items[next].focus();
    }
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
    safely(askAI(question));
    return;
  }
  if (event.target.id === 'find-input' && event.key === 'Enter') {
    event.preventDefault();
    safely(invoke('find', { text: ui.findText, forward: !event.shiftKey, findNext: true }));
    return;
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
function clearDragFeedback() {
  $$('.drag-over,.drop-before,.drop-after').forEach((element) =>
    element.classList.remove('drag-over', 'drop-before', 'drop-after'),
  );
}
function dragDestination(event) {
  const drop = event.target.closest('[data-drop-tab],[data-drop-pinned],[data-drop-folder]');
  const source = state?.tabs.find((tab) => tab.id === ui.dragTab);
  if (!drop || !source || source.profileId !== activeProfile()?.id) return null;
  const target = drop.dataset.dropTab ? state.tabs.find((tab) => tab.id === drop.dataset.dropTab) : null;
  if (target?.id === source.id) return null;
  const pinned = Boolean(drop.closest('[data-drop-pinned]'));
  const rectangle = drop.getBoundingClientRect();
  const after =
    target &&
    (pinned
      ? event.clientX > rectangle.left + rectangle.width / 2
      : event.clientY > rectangle.top + rectangle.height / 2);
  const remaining = state.tabs.filter((tab) => tab.id !== source.id);
  let index;
  if (target) index = remaining.findIndex((tab) => tab.id === target.id) + (after ? 1 : 0);
  else {
    const siblings = remaining.filter(
      (tab) =>
        tab.spaceId === state.activeSpaceId &&
        (pinned ? tab.pinned : !tab.pinned && (tab.folderId || '') === (drop.dataset.dropFolder || '')),
    );
    index = siblings.length ? remaining.indexOf(siblings.at(-1)) + 1 : remaining.length;
  }
  return {
    drop,
    after,
    payload: {
      id: source.id,
      spaceId: target?.spaceId || state.activeSpaceId,
      pinned,
      folderId: pinned ? null : target ? target.folderId : drop.dataset.dropFolder || null,
      index,
    },
  };
}
document.addEventListener('dragstart', (event) => {
  const tab = event.target.closest('[data-tab-id]');
  if (!tab || !event.dataTransfer) return;
  interruptSpaceScroll();
  ui.dragTab = tab.dataset.tabId;
  $('#app').dataset.dragging = 'true';
  event.dataTransfer.effectAllowed = 'move';
  event.dataTransfer.setData('text/plain', ui.dragTab);
});
document.addEventListener('dragover', (event) => {
  const destination = dragDestination(event);
  if (!destination) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'move';
  clearDragFeedback();
  destination.drop.classList.add(
    destination.drop.dataset.dropTab ? (destination.after ? 'drop-after' : 'drop-before') : 'drag-over',
  );
});
document.addEventListener('dragleave', (event) => {
  const drop = event.target.closest('[data-drop-tab],[data-drop-pinned],[data-drop-folder]');
  if (drop && !drop.contains(event.relatedTarget))
    drop.classList.remove('drag-over', 'drop-before', 'drop-after');
});
function endTabDrag() {
  ui.dragTab = null;
  delete $('#app').dataset.dragging;
  clearDragFeedback();
}
document.addEventListener('dragend', endTabDrag);
document.addEventListener('drop', (event) => {
  const destination = dragDestination(event);
  if (!destination) {
    endTabDrag();
    return;
  }
  event.preventDefault();
  endTabDrag();
  safely(invoke('tab:move', destination.payload));
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
    `<div class="dialog-header">${mark}<h2>Zacro</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">An independent, open-source browser by Zacro Technologies.</p><div class="shortcut-grid"><span>Zacro</span><span>${esc(details.version)}</span><span>Chromium</span><span>${esc(details.chromium)}</span><span>Electron</span><span>${esc(details.electron)}</span><span>Platform</span><span>${esc(details.platform)}</span></div><p class="provider-note">Original code is licensed under MIT. Chromium and other components retain their respective licenses. Zacro is not affiliated with The Browser Company.</p><div class="dialog-footer">${secondary('app:check-updates', 'View releases', 'external')}${primary('ui:dialog-close', 'Done')}</div></div>`,
    { title: 'About Zacro' },
  );
}

document.addEventListener(
  'error',
  (event) => {
    const image = event.target;
    if (image instanceof HTMLImageElement && image.closest('.favicon')) {
      image.parentElement.classList.add('favicon-placeholder');
      image.parentElement.innerHTML = icon('globe');
    }
  },
  true,
);
$('#sidebar').addEventListener('wheel', onSpaceScroll, { passive: false });
$('#sidebar').addEventListener('pointerleave', interruptSpaceScroll);
window.addEventListener('blur', () => {
  interruptSpaceScroll();
  stopShortcutRecording();
  if (ui.dialog === 'shortcuts') renderShortcutRows();
});
window.addEventListener('resize', () => {
  interruptSpaceScroll();
  syncLayout();
  const popover = $('.popover-panel');
  if (popover) {
    const rect = popover.getBoundingClientRect();
    popover.style.left = `${Math.max(8, Math.min(rect.left, innerWidth - rect.width - 8))}px`;
    popover.style.top = `${Math.max(8, Math.min(rect.top, innerHeight - rect.height - 8))}px`;
  }
});
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
