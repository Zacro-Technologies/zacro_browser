import { createSpaceGesture } from './space-gesture.js';
import { blendSpaceAppearance, deriveSpaceTheme } from './theme.js';
import '../core/site-search.js';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const esc = (value = '') =>
  String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const icons = {
  circle: 'M20 12a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  briefcase: 'M3 7h18v14H3zM8 7V3h8v4M3 12h18M10 12v3h4v-3',
  home: 'm3 10 9-7 9 7M5 9v12h14V9M9 21v-8h6v8',
  code: 'm8 6-6 6 6 6M16 6l6 6-6 6M14 3l-4 18',
  book: 'M12 5v16M12 5C8 2 4 3 2 4v16c4-2 7-1 10 1 3-2 6-3 10-1V4c-2-1-6-2-10 1',
  leaf: 'M20 3C10 2 3 7 4 14c1 7 12 8 15-2 1-3 1-6 1-9M4 21l11-12',
  music: 'M9 18V5l12-3v13M9 8l12-3M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0M21 15a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
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
  plane: 'm22 2-7 20-4-9-9-4zM11 13 22 2',
  camera: 'M3 7h4l2-3h6l2 3h4v14H3zM16 13a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  gamepad: 'M7 7h10c3 0 5 12 2 12l-4-3H9l-4 3C2 19 4 7 7 7zM7 10v5M4.5 12.5h5M16 11h.01M19 14h.01',
  palette:
    'M12 3a9 9 0 1 0 0 18h2a2 2 0 0 0 0-4 2 2 0 0 1 0-4h3a4 4 0 0 0 4-4c0-3-4-6-9-6zM7 8h.01M12 6h.01M6 13h.01M17 8h.01',
  beaker: 'M8 3h8M9 3v7L3 20h18l-6-10V3M7 14h10',
  rocket: 'M14 4c3-2 6-2 7-1 1 1 1 4-1 7l-8 8-6-6zM14 4H7l-4 7 5 1M20 10v7l-7 4-1-5M5 16l-2 5 5-2M17 6h.01',
  compass: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M16 8l-3 5-5 3 3-5z',
  mountain: 'm2 20 7-14 5 9 3-5 5 10zM6 12l3 2 3-2',
  flame: 'M12 2c1 6-5 7-5 12a5 5 0 0 0 10 0c0-3-1-5-2-7 0 4-2 4-2 4 1-4 0-7-1-9z',
  cloud: 'M6 19a5 5 0 0 1-1-10 7 7 0 0 1 13-1 5.5 5.5 0 0 1 0 11z',
  bolt: 'm13 2-9 12h7l-1 8 10-13h-8z',
  diamond: 'm12 2 10 10-10 10L2 12z',
  flower: 'M12 8c-8-12-13 1-5 4-8 3-3 16 5 4 8 12 13-1 5-4 8-3 3-16-5-4zM14 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0',
  smile: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M8 9h.01M16 9h.01M8 14q4 5 8 0',
  headphones:
    'M4 14v-3a8 8 0 0 1 16 0v3M4 12h3v9H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2M20 12h-3v9h3a2 2 0 0 0 2-2v-5a2 2 0 0 0-2-2',
  calendar: 'M3 5h18v16H3zM3 10h18M8 2v6M16 2v6M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01',
  film: 'M3 3h18v18H3zM7 3v18M17 3v18M3 8h4M3 16h4M17 8h4M17 16h4',
  building: 'M4 21V7h6V3h10v18M2 21h20M14 7h2M14 11h2M14 15h2M7 11h.01M7 15h.01M10 21v-4h4v4',
  bag: 'M4 7h16l1 14H3zM8 8V6a4 4 0 0 1 8 0v2',
};
const icon = (name) =>
  `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${icons[name] || icons.globe}"/></svg>`;
const mark =
  '<span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 32 32"><path d="M10 10h12L10 22h12"/></svg></span>';
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
  ['rose', '#cf667d'],
  ['amber', '#b68535'],
  ['mint', '#4f9485'],
  ['sky', '#6192bd'],
  ['orchid', '#a466b5'],
  ['ink', '#353d60'],
];
const spaceIcons = [
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
  commandFilter: 'all',
  commandAuto: false,
  commandBusy: false,
  commandTrail: [],
  commandContext: null,
  commandSiteSearch: null,
  blankPaletteContext: null,
  shortcutQuery: '',
  recordingShortcut: null,
  shortcutError: '',
  onboardingOffered: false,
  onboardingStep: 0,
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
  aiGrantedPages: [],
  aiDraft: '',
  aiSavedQuestions: [],
  aiRequestId: null,
  aiContextSerial: 0,
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
  if (!state || ui.commandBusy || !isBlankPage() || ui.dialog || ui.panel || ui.dragTab || ui.libraryMenuOpen)
    return;
  const context = blankContext();
  if (ui.blankPaletteContext === context) return;
  ui.blankPaletteContext = context;
  requestAnimationFrame(() => {
    if (
      !ui.dialog &&
      !ui.panel &&
      !ui.commandBusy &&
      !ui.libraryMenuOpen &&
      isBlankPage() &&
      blankContext() === context
    )
      openCommand('newtab', '', { automatic: true });
  });
}
const sidebarScroll = new Map();
const favoriteScroll = new Map();
const spaceGesture = createSpaceGesture();
let spaceGestureTimer;
let spaceGesturePending = false;
let spaceGestureFeedback = null;
let spaceTransition = null;
let spacePreview = null;
let spaceAppearance = null;
let spaceAppearanceSerial = 0;
let spaceMaterialRequestSerial = 0;
function presentedSpaceAppearance() {
  return spaceAppearance
    ? blendSpaceAppearance(spaceAppearance.from, spaceAppearance.to, spaceAppearance.progress)
    : activeSpace();
}
function releaseSpaceAppearanceMaterial(record) {
  if (!record?.materialToken) return;
  const token = record.materialToken;
  const serial = ++spaceMaterialRequestSerial;
  record.materialToken = null;
  void invoke('window:space-material-transition', { clear: true, token })
    .then((material) => {
      if (serial !== spaceMaterialRequestSerial || spaceAppearance || ui.themePreview || !state?.runtime)
        return;
      state.runtime.windowMaterial = material;
      setTheme();
    })
    .catch(() => {});
}
function holdSpaceAppearanceMaterial(record) {
  if (Math.min(record.from.theme?.opacity ?? 100, record.to.theme?.opacity ?? 100) >= 100) return;
  const now = performance.now();
  if (record.materialToken && now - record.materialRequestedAt < 1000) return;
  record.materialToken ||= `space-${Date.now()}-${++spaceAppearanceSerial}`;
  record.materialRequestedAt = now;
  const token = record.materialToken;
  const serial = ++spaceMaterialRequestSerial;
  void invoke('window:space-material-transition', {
    token,
    fromId: record.fromId,
    toId: record.toId,
    opacity: Math.min(record.from.theme?.opacity ?? 100, record.to.theme?.opacity ?? 100),
  })
    .then((material) => {
      if (
        serial !== spaceMaterialRequestSerial ||
        spaceAppearance !== record ||
        record.materialToken !== token ||
        !state?.runtime
      )
        return;
      state.runtime.windowMaterial = material;
      setTheme();
    })
    .catch(() => {});
}
function clearSpaceAppearance({ paint = true } = {}) {
  const previous = spaceAppearance;
  spaceAppearance = null;
  if (previous) cancelAnimationFrame(previous.frame);
  releaseSpaceAppearanceMaterial(previous);
  if (paint && state) setTheme();
}
function beginSpaceAppearance(from, to, { fromId = from?.id, progress = 0, tracking = false } = {}) {
  clearSpaceAppearance({ paint: false });
  if (!from || !to || !fromId) return null;
  spaceAppearance = {
    from: structuredClone(from),
    to: structuredClone(to),
    fromId,
    toId: to.id,
    profileId: to.profileId,
    progress,
    tracking,
  };
  holdSpaceAppearanceMaterial(spaceAppearance);
  return spaceAppearance;
}
function paintSpaceAppearance(record, progress) {
  if (!record || spaceAppearance !== record) return;
  record.progress = Math.max(0, Math.min(1, progress));
  setTheme();
}
function settleSpaceAppearance(record, animation, destination) {
  if (!record || spaceAppearance !== record) return;
  cancelAnimationFrame(record.frame);
  record.tracking = false;
  const start = record.progress;
  const finish = () => {
    if (spaceAppearance !== record) return;
    paintSpaceAppearance(record, destination);
    clearSpaceAppearance();
  };
  if (!animation || reducedMotion.matches) return finish();
  const sample = () => {
    if (spaceAppearance !== record) return;
    const progress = animation.effect?.getComputedTiming().progress;
    if (progress !== null && progress !== undefined)
      paintSpaceAppearance(record, start + (destination - start) * progress);
    if (animation.playState === 'running' || animation.pending) record.frame = requestAnimationFrame(sample);
  };
  sample();
  animation.finished.then(finish).catch(() => {});
}
const visibleSpacePage = () => $('#sidebar-content > .space-page');
function clearSpacePreview() {
  const preview = $('#space-gesture-preview');
  if (spacePreview?.page) elementMotions.get(spacePreview.page)?.cancel();
  spacePreview = null;
  if (preview) {
    preview.hidden = true;
    preview.replaceChildren();
  }
}
function inertSpacePage(page) {
  page.classList.remove('space-page', 'gesture-tracking');
  page.classList.add('space-preview-page');
  for (const node of [page, ...page.querySelectorAll('*')]) {
    for (const attribute of [...node.attributes])
      if (attribute.name === 'id' || attribute.name.startsWith('data-')) node.removeAttribute(attribute.name);
    node.removeAttribute('draggable');
    node.removeAttribute('aria-current');
    if (node.matches('button, input, select, textarea, a, [tabindex]')) node.tabIndex = -1;
  }
  for (const scroll of $$('.tabs-scroll', page)) {
    scroll.classList.remove('tabs-scroll');
    scroll.classList.add('space-preview-scroll');
  }
  page.inert = true;
  page.setAttribute('aria-hidden', 'true');
  return page;
}
function clearSpaceTransition() {
  const previous = spaceTransition;
  spaceTransition = null;
  previous?.incoming?.cancel();
  previous?.outgoing?.cancel();
  previous?.wrapper?.remove();
}
function resetSpaceFeedback({ animate = false, preserveTransition = false, duration = 140 } = {}) {
  const list = visibleSpacePage();
  const feedback = spaceGestureFeedback;
  const offset = feedback?.offset || 0;
  let returnAnimation = null;
  spaceGestureFeedback = null;
  if (list) {
    list.style.removeProperty('transform');
    list.style.removeProperty('opacity');
    list.style.removeProperty('visibility');
    list.classList.remove('gesture-tracking');
    if (animate && offset)
      returnAnimation = motion(
        list,
        [{ transform: `translateX(${offset}px)` }, { transform: 'translateX(0)' }],
        duration,
      );
  }
  const preview = spacePreview;
  if (animate && offset && preview && !reducedMotion.matches) {
    const destination = feedback.direction * feedback.travel;
    const animation = motion(
      preview.page,
      [{ transform: `translateX(${destination + offset}px)` }, { transform: `translateX(${destination}px)` }],
      duration,
    );
    animation?.finished
      .then(() => {
        if (spacePreview === preview) clearSpacePreview();
      })
      .catch(() => {});
  } else clearSpacePreview();
  if (!preserveTransition) {
    clearSpaceTransition();
    if (animate && offset) settleSpaceAppearance(spaceAppearance, returnAnimation, 0);
    else clearSpaceAppearance();
  }
}
function interruptSpaceScroll({ preserveTransition = false } = {}) {
  clearTimeout(spaceGestureTimer);
  spaceGesture.interrupt(performance.now());
  resetSpaceFeedback({ preserveTransition });
}
function paintSpaceFeedback(result) {
  const list = visibleSpacePage();
  if (!spaceGestureFeedback) {
    clearSpaceTransition();
    clearSpacePreview();
    elementMotions.get(list)?.cancel();
  }
  spaceGestureFeedback = { ...result, profileId: activeProfile()?.id, spaceId: state.activeSpaceId };
  if (list) {
    list.classList.add('gesture-tracking');
    list.style.transform = `translateX(${result.offset}px)`;
  }
  const spaces = state.spaces.filter((space) => space.profileId === activeProfile()?.id);
  const next = spaces[result.targetIndex];
  if (next) {
    if (
      !spaceAppearance?.tracking ||
      spaceAppearance.fromId !== state.activeSpaceId ||
      spaceAppearance.toId !== next.id
    )
      beginSpaceAppearance(activeSpace(), next, { tracking: true });
    holdSpaceAppearanceMaterial(spaceAppearance);
    paintSpaceAppearance(spaceAppearance, Math.min(1, Math.abs(result.offset) / result.travel));
  } else clearSpaceAppearance();
  const preview = $('#space-gesture-preview');
  if (!preview || !list) return;
  if (!next) return clearSpacePreview();
  if (spacePreview?.spaceId !== next.id || spacePreview.state !== state) {
    clearSpacePreview();
    const page = document.createElement('div');
    page.innerHTML = renderSpacePage(next);
    inertSpacePage(page);
    preview.append(page);
    spacePreview = { spaceId: next.id, state, page };
  }
  const bounds = list.getBoundingClientRect();
  const sidebar = $('#sidebar').getBoundingClientRect();
  Object.assign(preview.style, {
    left: `${bounds.left - sidebar.left - result.offset}px`,
    top: `${bounds.top - sidebar.top}px`,
    width: `${list.clientWidth}px`,
    height: `${list.clientHeight}px`,
  });
  preview.hidden = false;
  spacePreview.page.style.transform = `translateX(${result.direction * result.travel + result.offset}px)`;
  $('.space-preview-scroll', spacePreview.page).scrollTop = sidebarScroll.get(next.id) || 0;
  $('.favorites', spacePreview.page).scrollTop = favoriteScroll.get(next.id) || 0;
}
function prepareSpaceTransition(nextId, result, gesture = false) {
  clearSpaceTransition();
  const list = visibleSpacePage();
  const record = {
    ...result,
    gesture,
    fromSpaceId: ui.sidebarSpaceId,
    toSpaceId: nextId,
    profileId: activeProfile()?.id,
    appearance: spaceAppearance?.toId === nextId ? spaceAppearance : null,
  };
  spaceTransition = record;
  if (!list || reducedMotion.matches) return record;
  const bounds = list.getBoundingClientRect();
  const wrapper = document.createElement('div');
  wrapper.className = 'space-transition-snapshot';
  wrapper.setAttribute('aria-hidden', 'true');
  wrapper.inert = true;
  Object.assign(wrapper.style, {
    position: 'fixed',
    left: `${bounds.left - result.fromOffset}px`,
    top: `${bounds.top}px`,
    width: `${list.clientWidth}px`,
    height: `${list.clientHeight}px`,
    overflow: 'hidden',
    pointerEvents: 'none',
    zIndex: '40',
  });
  const snapshot = inertSpacePage(list.cloneNode(true));
  Object.assign(snapshot.style, {
    width: '100%',
    height: '100%',
    overflow: 'hidden',
    opacity: '1',
    visibility: 'visible',
    padding: getComputedStyle(list).padding,
    transform: `translateX(${result.fromOffset}px)`,
  });
  wrapper.append(snapshot);
  document.body.append(wrapper);
  $('.space-preview-scroll', snapshot).scrollTop = $('.tabs-scroll', list).scrollTop;
  $('.favorites', snapshot).scrollTop = $('.favorites', list).scrollTop;
  record.wrapper = wrapper;
  record.snapshot = snapshot;
  list.style.visibility = 'hidden';
  return record;
}
function finishSpaceTransition(record, animation) {
  if (spaceTransition === record && record.incoming === animation) clearSpaceTransition();
}
function animateSpaceTransition(
  record,
  offset = record.direction * record.travel + record.fromOffset,
  duration = record.duration,
) {
  const list = visibleSpacePage();
  if (!list || spaceTransition !== record) return;
  list.style.removeProperty('visibility');
  record.incomingDuration = duration;
  record.incoming = motion(
    list,
    [{ transform: `translateX(${offset}px)` }, { transform: 'translateX(0)' }],
    duration,
  );
  if (!record.outgoing && record.snapshot)
    record.outgoing = motion(
      record.snapshot,
      [
        { transform: `translateX(${record.fromOffset}px)` },
        { transform: `translateX(${-record.direction * record.travel}px)` },
      ],
      record.duration,
    );
  const animation = record.incoming;
  settleSpaceAppearance(record.appearance, animation, 1);
  if (!animation) clearSpaceTransition();
  else animation.finished.then(() => finishSpaceTransition(record, animation)).catch(() => {});
}
function captureSpacePresentation() {
  const record = spaceTransition;
  const list = visibleSpacePage();
  if (record?.incoming?.playState !== 'running' || !list) return null;
  const timing = record.incoming.effect.getComputedTiming();
  return {
    record,
    offset: new DOMMatrix(getComputedStyle(list).transform).m41,
    duration:
      record.incomingDuration *
      Math.max(0, 1 - Number(record.incoming.currentTime || 0) / Number(timing.duration)),
  };
}
function restoreSpacePresentation(presentation) {
  if (spaceTransition?.fromSpaceId === state.activeSpaceId && visibleSpacePage())
    visibleSpacePage().style.visibility = 'hidden';
  else if (
    spaceGestureFeedback?.spaceId === state.activeSpaceId &&
    spaceGestureFeedback.profileId === activeProfile()?.id
  )
    paintSpaceFeedback(spaceGestureFeedback);
  else if (presentation?.record === spaceTransition && spaceTransition.toSpaceId === state.activeSpaceId)
    animateSpaceTransition(spaceTransition, presentation.offset, presentation.duration);
}
function handleSpaceGesture(result) {
  clearTimeout(spaceGestureTimer);
  if (result.idleDelay) spaceGestureTimer = setTimeout(settleSpaceGesture, result.idleDelay);
  if (['tracking', 'edge'].includes(result.phase)) paintSpaceFeedback(result);
  if (result.phase === 'settling') resetSpaceFeedback({ animate: true, duration: result.duration });
  if (result.phase === 'idle' && spaceGestureFeedback) resetSpaceFeedback({ animate: true });
  if (!result.commit) return;
  const spaces = state?.spaces.filter((space) => space.profileId === activeProfile()?.id) || [];
  const next = spaces[result.targetIndex];
  if (
    !next ||
    result.contextKey !== activeProfile()?.id ||
    result.originIndex !== spaces.findIndex((space) => space.id === state.activeSpaceId)
  ) {
    interruptSpaceScroll();
    return;
  }
  prepareSpaceTransition(next.id, result, true);
  spaceGesturePending = true;
  $('#live-region').textContent = `Switching to ${next.name}`;
  safely(
    invoke('space:activate', { id: next.id })
      .catch((error) => {
        interruptSpaceScroll();
        throw error;
      })
      .finally(() => {
        spaceGesturePending = false;
      }),
  );
}
function settleSpaceGesture() {
  handleSpaceGesture(spaceGesture.settle(performance.now()));
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
    phase: ['began', 'begin', 'changed', 'ended', 'end', 'cancelled'].includes(event.phase)
      ? event.phase
      : undefined,
    time: performance.now(),
    width: sidebar.clientWidth,
    index: spaces.findIndex((space) => space.id === state?.activeSpaceId),
    count: spaces.length,
    contextKey: activeProfile()?.id,
    blocked:
      !state ||
      effectiveSidebarHidden() ||
      sidebar.inert ||
      (ui.dialog && ui.dialog !== 'command') ||
      ui.dragTab ||
      spaceGesturePending ||
      Boolean(
        event.target.closest('#toolbar, .space-dots, input, textarea, select, [contenteditable="true"]'),
      ),
  });
  if (result.preventDefault) event.preventDefault();
  if (['blocked', 'vertical'].includes(result.phase) && spaceGestureFeedback && !spaceGesturePending)
    resetSpaceFeedback();
  handleSpaceGesture(result);
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
    const original = error?.message || String(error);
    const message = original.replace(/^Error invoking remote method 'zacro:invoke': Error: /, '');
    toast(message, true);
    // Keep validation and provider errors intact; remove only Electron's IPC
    // transport envelope from the text presented by forms and dialogs.
    if (message !== original) throw new Error(message, { cause: error });
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
    const clip = document.createElement('div');
    clip.className = 'page-backdrop-frame';
    Object.assign(clip.style, {
      left: `${bounds.x}px`,
      top: `${bounds.y}px`,
      width: `${bounds.width}px`,
      height: `${bounds.height}px`,
    });
    picture.addEventListener('error', () => picture.remove(), { once: true });
    clip.append(picture);
    root.append(clip);
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
  finishChromeMotion();
  syncLayout();
});
function motion(element, frames, duration = 140) {
  elementMotions.get(element)?.cancel();
  if (!element || reducedMotion.matches || !element.animate) return null;
  const animation = element.animate(frames, {
    duration: duration * (state?.settings.motionScale || 1),
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
  if (
    spaceAppearance &&
    (spaceAppearance.profileId !== activeProfile()?.id ||
      ![spaceAppearance.fromId, spaceAppearance.toId].includes(state.activeSpaceId) ||
      !state.spaces.some((item) => item.id === spaceAppearance.toId))
  )
    clearSpaceAppearance({ paint: false });
  const space = ui.themePreview || presentedSpaceAppearance();
  const base = space?.color;
  const material = space?.theme || {};
  const root = document.documentElement;
  root.dataset.tabDensity = state.settings.tabDensity || 'comfortable';
  root.style.setProperty('--page-gutter', `${state.settings.pageGutter ?? 8}px`);
  root.style.setProperty('--page-radius', `${state.settings.pageRadius ?? 12}px`);
  root.style.setProperty('--sidebar-expanded', `${state.settings.sidebarWidth || 224}px`);
  root.style.setProperty(
    '--space-secondary',
    /^#[\da-f]{6}$/i.test(material.secondaryColor || '') ? material.secondaryColor : base || '#786298',
  );
  root.style.setProperty('--space-gradient', `${material.gradient ?? 50}%`);
  const tones = deriveSpaceTheme({
    color: base,
    secondaryColor: material.secondaryColor,
    dark,
    grain: material.grain,
  });
  for (const [token, key] of [
    ['--chrome', 'chrome'],
    ['--space-tint-primary', 'tintPrimary'],
    ['--space-tint-secondary', 'tintSecondary'],
    ['--hover', 'hover'],
    ['--accent', 'accent'],
    ['--accent-soft', 'accentSoft'],
    ['--space-grain', 'grainOpacity'],
  ])
    root.style.setProperty(token, String(tones[key]));
  const nativeMaterial = state.runtime?.windowMaterial;
  root.dataset.windowMaterial = nativeMaterial?.enabled ? nativeMaterial.type : 'opaque';
  root.style.setProperty('--space-opacity', `${nativeMaterial?.enabled ? (material.opacity ?? 100) : 100}%`);
  root.style.setProperty('--space-blur', '0px');
  for (const [name, duration] of [
    ['fast', 100],
    ['base', 160],
    ['enter', 180],
  ])
    root.style.setProperty(`--motion-${name}`, `${duration * (state.settings.motionScale || 1)}ms`);
  document.documentElement.style.setProperty(
    '--space-color',
    /^#[\da-f]{6}$/i.test(base || '') ? base : '#9d4460',
  );
}
function previewWindowMaterial(opacity) {
  const serial = (ui.materialPreviewSerial = (ui.materialPreviewSerial || 0) + 1);
  safely(
    invoke(
      'window:material-preview',
      opacity === null ? { clear: true } : { spaceId: state.activeSpaceId, opacity },
    ).then((material) => {
      if (serial !== ui.materialPreviewSerial || !state?.runtime) return;
      state.runtime.windowMaterial = material;
      setTheme();
    }),
  );
}
function applyState(next) {
  if (!next?.profiles || !next?.tabs) return;
  const previousProfile = activeProfile()?.id;
  const previousSpace = state?.activeSpaceId;
  const previousAppearance = presentedSpaceAppearance();
  const previousTab = state?.activeTabId;
  state = next;
  if (previousProfile && previousProfile !== activeProfile()?.id) clearSpaceAppearance({ paint: false });
  else if (
    previousSpace &&
    previousSpace !== state.activeSpaceId &&
    !ui.themePreview &&
    !(spaceTransition?.toSpaceId === state.activeSpaceId && spaceAppearance?.toId === state.activeSpaceId)
  )
    beginSpaceAppearance(previousAppearance, activeSpace(), { fromId: previousSpace });
  if (previousSpace !== state.activeSpaceId || previousProfile !== activeProfile()?.id) {
    closeLibraryChooser();
    cancelRailResize();
  }
  if (ui.themePreview && (previousSpace !== state.activeSpaceId || previousProfile !== activeProfile()?.id))
    closeDialog({ restore: false });
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
      ui.commandTrail = [];
      ui.commandContext = null;
      ui.commandSiteSearch = null;
      $('#command-input').value = '';
    }
    invalidateAIRequest();
    ui.aiMessages = [];
    ui.aiSources = [];
    ui.aiTabs = [];
    ui.aiGrantedPages = [];
    ui.aiDraft = '';
    ui.aiSavedQuestions = [];
    ui.aiContextSerial++;
    ui.aiContextChanging = false;
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
  maybeOpenOnboarding();
  maybeOpenBlankPalette();
  if (previousSpace && previousSpace !== state.activeSpaceId) {
    const transition = spaceTransition?.toSpaceId === state.activeSpaceId ? spaceTransition : null;
    interruptSpaceScroll({ preserveTransition: Boolean(transition) });
    const spaces = state.spaces.filter((space) => space.profileId === activeProfile()?.id);
    const previousIndex = spaces.findIndex((space) => space.id === previousSpace);
    const nextIndex = spaces.findIndex((space) => space.id === state.activeSpaceId);
    const direction = previousIndex < 0 ? 1 : Math.sign(nextIndex - previousIndex);
    if (transition) animateSpaceTransition(transition);
    else
      motion(
        visibleSpacePage(),
        [
          { opacity: 0.65, transform: `translateX(${direction * $('#sidebar').clientWidth}px)` },
          { opacity: 1, transform: 'translateX(0)' },
        ],
        220,
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
    prepareSidebarKeyboard();
    renderToolbar();
    renderWorkspace();
    renderPanel();
    renderPageMenu();
    if (ui.dialog === 'command') renderCommands({ preserve: true });
    if (ui.dialog === 'shortcuts') renderShortcutRows();
    if (ui.dialog === 'onboarding') renderOnboardingShortcuts();
  });
  syncLayout();
}
function sidebarKeyboardItems() {
  return $$(
    '#sidebar-content .space-page .favorite, #sidebar-content .space-page .folder-heading, #sidebar-content .space-page .tab-main',
  ).filter((item) => !item.closest('[inert]') && item.getClientRects().length);
}
function prepareSidebarKeyboard() {
  const items = sidebarKeyboardItems();
  const selected =
    items.find((item) => item.dataset.key === ui.sidebarFocusKey) ||
    items.find((item) => item.getAttribute('aria-current') === 'page') ||
    items[0];
  for (const item of items) item.tabIndex = item === selected ? 0 : -1;
  // Context menus expose row actions; avoid a close/mute stop for every tab.
  for (const item of $$('#sidebar-content .tab-close, #sidebar-content .tab-audio')) item.tabIndex = -1;
}
async function focusSidebar() {
  interruptSpaceScroll();
  const token = ui.dialogToken;
  const next = await invoke('state:get');
  if (ui.dialog || token !== ui.dialogToken) return;
  // Native tab creation can precede the batched renderer state publication.
  // Reveal the current host tab even when this shortcut immediately follows it.
  applyState(next);
  const tab = activeTab();
  if (tab?.folderId) ui.closedFolders.delete(tab.folderId);
  if (effectiveSidebarHidden()) toggleSidebar();
  // An explicitly hidden sidebar and a compact panel can both hide it. The
  // focus command must resolve both causes in the same invocation.
  if (effectiveSidebarHidden() && ui.panel) closePanel();
  render();
  requestAnimationFrame(() => {
    if (ui.dialog) return;
    const items = sidebarKeyboardItems();
    const target =
      items.find((item) => item.dataset.id === state.activeTabId) ||
      items[0] ||
      $('[data-key="space-picker"]');
    target?.focus({ preventScroll: true });
    target?.scrollIntoView({ block: 'nearest' });
  });
}
function handleSidebarKeyboard(event) {
  if (ui.dialog || event.ctrlKey || event.metaKey || event.altKey) return false;
  const items = sidebarKeyboardItems();
  const current = items.indexOf(event.target);
  if (current < 0) return false;
  if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
    event.preventDefault();
    const folder = event.target.matches('.folder-heading');
    if (folder) showFolderMenu(event.target.dataset.id);
    else showTabMenu(event.target.dataset.id);
    return true;
  }
  if (event.shiftKey) return false;
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
    event.preventDefault();
    const next =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? items.length - 1
          : Math.max(0, Math.min(items.length - 1, current + (event.key === 'ArrowDown' ? 1 : -1)));
    items[next]?.focus();
    items[next]?.scrollIntoView({ block: 'nearest' });
    return true;
  }
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
    const heading = event.target.matches('.folder-heading')
      ? event.target
      : event.target.closest('.folder')?.querySelector('.folder-heading');
    if (heading) {
      event.preventDefault();
      const id = heading.dataset.id;
      if (event.key === 'ArrowLeft' && event.target !== heading) heading.focus();
      else if (event.key === 'ArrowLeft' && !ui.closedFolders.has(id)) {
        ui.closedFolders.add(id);
        render();
      } else if (event.key === 'ArrowRight' && ui.closedFolders.has(id)) {
        ui.closedFolders.delete(id);
        render();
      } else if (event.key === 'ArrowRight') items[current + 1]?.focus();
      return true;
    }
    if (event.target.matches('.favorite')) {
      const pins = items.filter((item) => item.matches('.favorite'));
      event.preventDefault();
      pins[
        Math.max(
          0,
          Math.min(pins.length - 1, pins.indexOf(event.target) + (event.key === 'ArrowRight' ? 1 : -1)),
        )
      ]?.focus();
      return true;
    }
  }
  return false;
}
function tabLabel(tab) {
  return (
    tab.customTitle || (tab.pinned && tab.pinnedTitle) || tab.title || hostname(tab.pinnedUrl || tab.url)
  );
}
function renderSpacePage(space) {
  const profile = state.profiles.find((item) => item.id === space?.profileId);
  const favorites = state.tabs.filter((tab) => tab.favorite && tab.profileId === space?.profileId);
  const tabs = state.tabs.filter((tab) => tab.spaceId === space?.id && !tab.favorite);
  const selectedTabId = space?.id === state.activeSpaceId ? state.activeTabId : space?.lastActiveTabId;
  const pins = tabs.filter((tab) => tab.pinned && !tab.folderId);
  const loose = tabs.filter(
    (tab) => !tab.pinned && !tab.folderId && (tab.url !== 'zacro://newtab' || tab.homePage),
  );
  const folders = state.folders.filter((folder) => folder.spaceId === space?.id);
  const tabRow = (tab) => {
    const page = state.runtime?.pages?.[tab.id];
    const label = tabLabel(tab);
    const status = tab.closed ? 'Closed' : page?.loaded ? 'Loaded' : 'Sleeping';
    const away = tab.pinned && !tab.closed && tab.pinnedUrl && tab.url !== tab.pinnedUrl;
    const glyph = page?.loading ? '<span class="spinner"></span>' : favicon(tab.pinnedUrl || tab.url, tab.id);
    return `<div class="tab-row ${tab.pinned ? 'pinned-row' : ''} ${away ? 'pin-navigated' : ''} ${tab.id === selectedTabId && !tab.closed ? 'active' : ''}" draggable="true" data-tab-id="${esc(tab.id)}" data-drop-tab="${esc(tab.id)}">${tab.pinned ? `<button type="button" class="tab-pin-reset" data-action="tab:reset-pin" data-id="${esc(tab.id)}" tabindex="-1" aria-label="Reset ${esc(label)} to saved page" title="Reset to ${esc(tab.pinnedUrl || tab.url)}">${glyph}<span class="pin-reset-symbol">${icon('back')}</span></button>` : ''}<button type="button" class="tab-main" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="tab-${esc(tab.id)}" ${tab.id === selectedTabId && !tab.closed ? 'aria-current="page"' : ''} title="${esc(label)} — ${esc(tab.url)}${tab.pinned ? ' · ' + status + (away ? ' · Away from saved page' : '') : ''}">${tab.pinned ? '' : glyph}${away ? '<span class="pin-away" aria-hidden="true">/</span>' : ''}<span class="title">${esc(label || 'New tab')}</span>${state.runtime?.splitTabId === tab.id ? icon('split') : ''}</button>${page?.audible || page?.muted ? button('tab:mute', page.muted ? 'Unmute tab' : 'Mute tab', page.muted ? 'muted' : 'volume', `data-id="${esc(tab.id)}"`, 'tab-audio') : ''}${button('tab:close', `Close ${label || 'tab'}${tab.pinned ? ' · keep pin' : ''}`, 'close', `data-id="${esc(tab.id)}" data-key="close-${esc(tab.id)}"`, 'tab-close')}</div>`;
  };
  // Balance every row, rather than leaving unused favorite slots. Twelve grid
  // tracks divide evenly into one, two, three or four tiles.
  const favoriteRows = Math.max(1, Math.ceil(favorites.length / 4));
  const rowSize = Math.floor(favorites.length / favoriteRows);
  const fullerRows = favorites.length % favoriteRows;
  const favoriteTiles = favorites
    .map((tab, index) => {
      const columns = index < fullerRows * (rowSize + 1) ? rowSize + 1 : rowSize;
      const page = state.runtime?.pages?.[tab.id];
      const status = tab.closed ? 'Closed' : page?.loaded ? 'Loaded' : 'Sleeping';
      const label = tabLabel(tab);
      return `<button type="button" data-columns="${columns}" class="favorite ${tab.id === selectedTabId && !tab.closed ? 'active' : ''} ${status.toLowerCase()}" draggable="true" data-tab-id="${esc(tab.id)}" data-drop-tab="${esc(tab.id)}" data-action="tab:activate" data-id="${esc(tab.id)}" data-key="pin-${esc(tab.id)}" ${tab.id === selectedTabId && !tab.closed ? 'aria-current="page"' : ''} aria-label="${esc(label)} — ${status}" title="${esc(label)} — ${status}\n${esc(tab.pinnedUrl || tab.url)}">${favicon(tab.pinnedUrl || tab.url, tab.id)}</button>`;
    })
    .join('');
  return `<div class="favorites ${favorites.length ? '' : 'favorites-empty'}" aria-label="Favorites" data-drop-favorites>${favoriteTiles || '<span class="pin-drop-hint">Drop to favorite</span>'}</div><div class="tabs-scroll">
    <div class="space-header"><button type="button" class="space-picker" data-action="ui:spaces" data-key="space-picker" aria-label="Switch Space or profile" title="${esc(space?.name)} · ${esc(profile?.name)}${profile?.private ? ' · Private session' : ''}">${icon(profile?.private ? 'shield' : space?.icon || 'circle')}<span class="space-title">${esc(space?.name || 'My Space')}</span>${profile?.private ? '<span class="private-indicator">Private</span>' : ''}${icon('down')}</button></div>
    <div class="pinned-tabs" data-drop-pinned aria-label="Pinned tabs">${folders
      .map(
        (folder) =>
          `<div class="folder" data-folder-id="${esc(folder.id)}" data-drop-folder="${esc(folder.id)}"><button type="button" class="folder-heading" data-action="ui:folder-toggle" data-id="${esc(folder.id)}" data-key="folder-${esc(folder.id)}" aria-expanded="${!ui.closedFolders.has(folder.id)}"><span class="folder-icon">${icon('folder')}${icon('down')}</span><span class="truncate">${esc(folder.name)}</span></button>${
            ui.closedFolders.has(folder.id)
              ? ''
              : `<div class="folder-tabs">${
                  tabs
                    .filter((tab) => tab.folderId === folder.id)
                    .map(tabRow)
                    .join('') || '<div class="empty-tabs">Drop tabs here</div>'
                }</div>`
          }</div>`,
      )
      .join('')}${pins.map(tabRow).join('')}<span class="pin-drop-hint">Drop to pin in this Space</span></div>
    <div class="today-divider" aria-hidden="true"></div><button type="button" class="new-tab today-new-tab" data-action="ui:new-tab" data-key="today-new-tab">${icon('plus')}<span>New tab</span><kbd>${shortcutFor('command-palette', 'Mod+T')}</kbd></button><div class="loose-tabs" data-drop-folder="" aria-label="Today tabs">${loose.map(tabRow).join('')}</div></div>`;
}
function renderSidebar() {
  const space = activeSpace();
  const profile = activeProfile();
  const tabs = state.tabs.filter(
    (tab) => tab.spaceId === space?.id || (tab.favorite && tab.profileId === profile?.id),
  );
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
      state.runtime?.pages?.[tab.id]?.loaded,
      state.runtime?.pages?.[tab.id]?.sleeping,
      state.runtime?.pages?.[tab.id]?.closed,
    ]),
    state.runtime?.splitTabId,
  ]);
  if (signature === ui.sidebarSignature) return;
  ui.sidebarSignature = signature;
  if (ui.sidebarSpaceId) {
    sidebarScroll.set(ui.sidebarSpaceId, $('.tabs-scroll')?.scrollTop || 0);
    favoriteScroll.set(ui.sidebarSpaceId, $('.favorites')?.scrollTop || 0);
  }
  for (const id of sidebarScroll.keys())
    if (!state.spaces.some((item) => item.id === id)) {
      sidebarScroll.delete(id);
      favoriteScroll.delete(id);
    }
  const scroll = sidebarScroll.get(space?.id) || 0;
  const oldRows = new Map(
    $$('[data-tab-id]', $('#sidebar')).map((row) => [row.dataset.tabId, row.getBoundingClientRect().top]),
  );
  const previousActive = $('[data-tab-id].active', $('#sidebar'))?.dataset.tabId;
  const sameSpace = ui.sidebarSpaceId === space?.id;
  const presentation = sameSpace ? captureSpacePresentation() : null;
  if (!sameSpace && ui.sidebarSpaceId && spaceTransition?.toSpaceId !== space?.id) {
    const spaces = state.spaces.filter((item) => item.profileId === profile?.id);
    const from = spaces.findIndex((item) => item.id === ui.sidebarSpaceId);
    const to = spaces.findIndex((item) => item.id === space?.id);
    if (from >= 0 && to >= 0)
      prepareSpaceTransition(space.id, {
        direction: Math.sign(to - from),
        travel: $('#sidebar').clientWidth,
        fromOffset: 0,
        duration: 220,
      });
    else clearSpaceTransition();
  }
  $('#sidebar-content').innerHTML = `<div class="space-page">${renderSpacePage(space)}</div>
    <footer class="sidebar-footer">${button('ui:library', 'Library', 'library', 'data-key="library" aria-haspopup="menu" aria-expanded="false"')}<div class="space-dots" aria-label="Your Spaces">${spaces.map((s) => `<button type="button" class="space-dot ${s.id === space?.id ? 'active' : ''}" data-action="space:activate" data-id="${esc(s.id)}" data-key="space-${esc(s.id)}" aria-haspopup="dialog" title="${esc(s.name)}" aria-label="Switch to ${esc(s.name)}" ${s.id === space?.id ? 'aria-current="true"' : ''}>${icon(s.icon || 'circle')}</button>`).join('')}</div>${button('ui:add-menu', 'New tab, folder or Space', 'plus', 'data-key="add-menu" aria-haspopup="dialog"')}</footer>`;
  syncLibraryChooserAnchor();
  for (const dot of $$('.space-dot')) {
    const color = spaces.find((item) => item.id === dot.dataset.id)?.color;
    if (/^#[\da-f]{6}$/i.test(color || '')) dot.style.setProperty('--dot-color', color);
  }
  $('.tabs-scroll').scrollTop = scroll;
  $('.favorites').scrollTop = favoriteScroll.get(space?.id) || 0;
  restoreSpacePresentation(presentation);
  if (!sameSpace) $('.space-dot.active')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  if (sameSpace && !spaceGestureFeedback && !spaceTransition)
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
  const sidebarHidden = effectiveSidebarHidden();
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
    sidebarHidden,
    state.runtime?.shortcuts,
  ]);
  if (signature === ui.toolbarSignature) return;
  ui.toolbarSignature = signature;
  const toolbar = $('#toolbar');
  const parent = sidebarHidden ? $('.main') : $('#sidebar');
  if (toolbar.parentElement !== parent) parent.prepend(toolbar);
  const controls =
    !isMac && !state.runtime?.fullScreen
      ? `<div class="window-controls">${button('window:minimize', 'Minimize', 'minimize')}${button('window:maximize', 'Maximize or restore', state.runtime?.maximized ? 'restore' : 'maximize')}${button('window:close', 'Close window', 'close', '', 'close-window')}</div>`
      : '';
  $('#captionbar').innerHTML = sidebarHidden ? '' : controls;
  $('#captionbar').hidden = sidebarHidden || !controls;
  $('#toolbar').innerHTML =
    `<div class="navigation"><span class="navigation-spacer"></span>${button('back', shortcutLabel('Back', 'history-back', isMac ? 'Mod+[' : 'Alt+Left'), 'back', `data-key="back" ${page.canGoBack ? '' : 'disabled'}`)}${button('forward', shortcutLabel('Forward', 'history-forward', isMac ? 'Mod+]' : 'Alt+Right'), 'forward', `data-key="forward" ${page.canGoForward ? '' : 'disabled'}`)}${button(page.loading ? 'stop' : 'reload', page.loading ? 'Stop loading' : shortcutLabel('Reload', 'reload', 'Mod+R'), page.loading ? 'close' : 'reload', `data-key="reload" ${blank ? 'disabled' : ''}`)}</div><div class="address-row"><button type="button" class="address-button" data-action="ui:address" data-key="address" title="${esc(tab?.url || 'Search or enter a URL')}" aria-label="Address bar: ${esc(tab?.url || 'New tab')}">${icon(blank ? 'search' : secure ? 'lock' : 'globe')}<span class="address-text">${esc(blank ? 'Search or enter URL' : sidebarHidden ? displayURL(tab.url) : hostname(tab.url))}</span></button>${button('ui:page-menu', 'Page actions', 'more', 'data-key="page-menu" aria-haspopup="dialog"')}</div>${sidebarHidden ? controls : ''}`;
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
    effectiveSidebarHidden(),
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
  const peekSignature = JSON.stringify(peek && [peek.id, peek.url, peek.title, peek.error]);
  if (peek && peekSignature !== ui.peekSignature) {
    $('#peek').innerHTML =
      `<div class="peek-bar"><span class="peek-label">Peek</span><span class="peek-url">${esc(peek.title || peek.url)}</span>${button('peek:promote', 'Open preview as a tab', 'external')}${button('peek:close', 'Close preview (Escape)', 'close', 'data-key="peek-close"')}</div><div class="peek-body">${peek.error ? `<div class="error-card"><div class="error-symbol">${icon('globe')}</div><h2>This preview couldn’t be loaded.</h2><p>${esc(peek.error.description || peek.error.message || 'Check the address and your connection.')}</p>${primary('reload', 'Try again', 'reload')}</div>` : ''}</div>`;
  }
  if (peek) paintPeekMotion(peek);
  ui.peekSignature = peekSignature;
}
function paintPeekMotion(frame) {
  const peek = state.runtime?.peek;
  if (!peek || !frame || frame.id !== peek.id) return;
  const offset = reducedMotion.matches ? 0 : Math.round(Math.max(0, Math.min(16, Number(frame.offset) || 0)));
  const progress = reducedMotion.matches ? 1 : Math.max(0, Math.min(1, frame.progress ?? 1));
  $('#peek').style.setProperty('--peek-offset', `${offset}px`);
  $('#peek').style.setProperty('--peek-progress', String(progress));
  $('#peek').dataset.phase = frame.phase || 'open';
}
function renderHome() {
  const draft = $('#home-query')?.value || '';
  const focused = document.activeElement?.id === 'home-query';
  const profile = activeProfile();
  const pins = currentTabs().filter((tab) => tab.pinned);
  const seen = new Set(effectiveSidebarHidden() ? [] : pins.map((tab) => tab.url));
  const links = [...(effectiveSidebarHidden() ? pins : []), ...profileItems('bookmarks')]
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
function expandedSidebarWidth() {
  const gutter = state?.settings.pageGutter ?? 8;
  return Math.min(
    Math.max(
      200,
      Math.min(
        380,
        ui.chromeResize?.kind === 'sidebar'
          ? ui.chromeResize.width
          : Number(state?.settings.sidebarWidth) || 224,
      ),
    ),
    Math.max(0, innerWidth - 240 - gutter * 2),
  );
}
function effectiveSidebarHidden() {
  const gutter = state?.settings.pageGutter ?? 8;
  return (
    ui.sidebarHidden || Boolean(ui.panel && innerWidth < expandedSidebarWidth() + 260 + 240 + gutter * 2)
  );
}
function chromeTargets() {
  const sidebar = effectiveSidebarHidden() ? 0 : expandedSidebarWidth();
  const gutter = state?.settings.pageGutter ?? 8;
  return {
    sidebar,
    panel: ui.panel
      ? Math.min(
          ui.chromeResize?.kind === 'panel'
            ? ui.chromeResize.width
            : Number(state.settings.panelWidth) || 336,
          Math.max(0, innerWidth - sidebar - 240 - gutter * 2),
        )
      : 0,
  };
}
function currentChromeWidths() {
  const targets = chromeTargets();
  return {
    sidebar: ui.sidebarAnimationWidth ?? targets.sidebar,
    panel: ui.panelAnimationWidth ?? targets.panel,
  };
}
function finishChromeMotion() {
  cancelAnimationFrame(ui.chromeAnimationFrame);
  ui.chromeAnimationFrame = null;
  ui.sidebarAnimationWidth = null;
  ui.panelAnimationWidth = null;
}
function animateChrome(start) {
  finishChromeMotion();
  const target = chromeTargets();
  if (reducedMotion.matches || (start.sidebar === target.sidebar && start.panel === target.panel)) {
    render();
    return;
  }
  ui.sidebarAnimationWidth = start.sidebar;
  ui.panelAnimationWidth = start.panel;
  const duration = 220 * (state.settings.motionScale || 1);
  const started = performance.now();
  render();
  const tick = (now) => {
    const progress = Math.min(1, (now - started) / duration);
    if (progress === 1 || reducedMotion.matches) {
      finishChromeMotion();
      syncLayout();
      return;
    }
    // One monotonic ease for both chrome rails. Reversals start at the current
    // displayed widths and native pages follow each sample without snapshots.
    const eased = 1 - Math.pow(1 - progress, 3);
    ui.sidebarAnimationWidth = Math.round(start.sidebar + (target.sidebar - start.sidebar) * eased);
    ui.panelAnimationWidth = Math.round(start.panel + (target.panel - start.panel) * eased);
    syncLayout();
    ui.chromeAnimationFrame = requestAnimationFrame(tick);
  };
  ui.chromeAnimationFrame = requestAnimationFrame(tick);
}
function syncLayout() {
  if (!state) return;
  const { sidebar: width, panel } = currentChromeWidths();
  const gutter = state.settings.pageGutter ?? 8;
  const hidden = effectiveSidebarHidden();
  if (ui.panel) ui.panelExpandedWidth = chromeTargets().panel;
  const contentTop = hidden || !$('#findbar').hidden ? 40 : isMac || state.runtime?.fullScreen ? gutter : 36;
  $('#app').dataset.panelOpen = String(Boolean(ui.panel));
  $('#app').dataset.sidebarHidden = String(hidden);
  $('#app').dataset.sidebarAnimating = String(ui.sidebarAnimationWidth != null);
  $('#app').dataset.panelAnimating = String(ui.panelAnimationWidth != null);
  $('#app').dataset.compactCanvas = String(innerWidth - width - panel - gutter * 2 < 420);
  $('#app').dataset.dialog = ui.dialog || '';
  $('#sidebar').inert = hidden || Boolean(ui.dialog && ui.dialog !== 'command');
  $('#sidebar').setAttribute('aria-hidden', String(hidden));
  $('#side-panel').hidden = !ui.panel && panel === 0;
  $('#side-panel').inert = !ui.panel || Boolean(ui.dialog);
  $('#side-panel').setAttribute('aria-hidden', String(!ui.panel));
  document.documentElement.style.setProperty('--sidebar', `${width}px`);
  document.documentElement.style.setProperty('--sidebar-expanded', `${expandedSidebarWidth()}px`);
  document.documentElement.style.setProperty('--panel', `${panel}px`);
  document.documentElement.style.setProperty('--panel-expanded', `${ui.panelExpandedWidth || 336}px`);
  document.documentElement.style.setProperty('--page-top', `${contentTop}px`);
  document.documentElement.style.setProperty('--canvas-right', `${panel + gutter}px`);
  for (const [kind, value, hiddenResize] of [
    ['sidebar', width, hidden],
    ['panel', panel, !ui.panel],
  ]) {
    const handle = $(`#${kind}-resizer`);
    handle.hidden = hiddenResize || Boolean(ui.dialog) || value === 0;
    handle.setAttribute('aria-valuemin', kind === 'sidebar' ? '200' : '260');
    handle.setAttribute('aria-valuemax', String(clampRailWidth(kind, 1000)));
    handle.setAttribute('aria-valuenow', String(Math.round(value)));
    handle.setAttribute('aria-valuetext', `${Math.round(value)} pixels`);
  }
  const layout = {
    sidebarWidth: width,
    panelWidth: panel,
    contentTop,
    overlay: Boolean(ui.dialog),
    peek: Boolean(state.runtime?.peek),
    reducedMotion: reducedMotion.matches,
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
function clampRailWidth(kind, value) {
  const gutter = state.settings.pageGutter ?? 8;
  const minimum = kind === 'sidebar' ? 200 : 260;
  const maximum = kind === 'sidebar' ? 380 : 560;
  // A deliberate sidebar resize must leave the open panel usable; otherwise
  // crossing its minimum would retract the very rail being dragged.
  const other =
    kind === 'sidebar' && ui.panel
      ? 260
      : kind === 'panel' && !effectiveSidebarHidden()
        ? expandedSidebarWidth()
        : 0;
  return Math.round(Math.max(minimum, Math.min(maximum, innerWidth - other - 240 - gutter * 2, value)));
}
async function saveRailWidth(kind, width) {
  const key = kind === 'sidebar' ? 'sidebarWidth' : 'panelWidth';
  const value = clampRailWidth(kind, width);
  try {
    await invoke('settings:update', { values: { [key]: value } });
    state.settings[key] = value;
  } finally {
    ui.chromeResize = null;
    delete $('#app').dataset.chromeResizing;
    syncLayout();
  }
}
document.addEventListener('pointerdown', (event) => {
  const handle = event.target.closest?.('.chrome-resizer');
  if (!handle || event.button !== 0 || !state) return;
  event.preventDefault();
  closeLibraryChooser();
  interruptSpaceScroll();
  finishChromeMotion();
  const kind = handle.id === 'sidebar-resizer' ? 'sidebar' : 'panel';
  const width = currentChromeWidths()[kind];
  ui.chromeResize = { kind, width, startWidth: width, startX: event.clientX, pointerId: event.pointerId };
  $('#app').dataset.chromeResizing = 'true';
  handle.focus({ preventScroll: true });
  handle.setPointerCapture(event.pointerId);
});
document.addEventListener('pointermove', (event) => {
  const resize = ui.chromeResize;
  if (!resize || resize.pointerId !== event.pointerId) return;
  resize.width = clampRailWidth(
    resize.kind,
    resize.startWidth + (event.clientX - resize.startX) * (resize.kind === 'sidebar' ? 1 : -1),
  );
  syncLayout();
});
document.addEventListener('pointerup', (event) => {
  const resize = ui.chromeResize;
  if (!resize || resize.pointerId !== event.pointerId) return;
  if (event.target.hasPointerCapture?.(event.pointerId)) event.target.releasePointerCapture(event.pointerId);
  safely(saveRailWidth(resize.kind, resize.width));
});
function cancelRailResize() {
  if (!ui.chromeResize) return;
  ui.chromeResize = null;
  delete $('#app').dataset.chromeResizing;
  syncLayout();
}
document.addEventListener('pointercancel', cancelRailResize);
document.addEventListener('dblclick', (event) => {
  const handle = event.target.closest?.('.chrome-resizer');
  if (!handle) return;
  const kind = handle.id === 'sidebar-resizer' ? 'sidebar' : 'panel';
  safely(saveRailWidth(kind, kind === 'sidebar' ? 224 : 336));
});
document.addEventListener(
  'keydown',
  (event) => {
    if (ui.chromeResize && event.key === 'Escape') {
      event.preventDefault();
      event.stopImmediatePropagation();
      cancelRailResize();
      return;
    }
    const handle = event.target.closest?.('.chrome-resizer');
    if (!handle || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const kind = handle.id === 'sidebar-resizer' ? 'sidebar' : 'panel';
    const step = event.shiftKey ? 32 : event.altKey ? 1 : 16;
    const change = (event.key === 'ArrowRight' ? 1 : -1) * (kind === 'sidebar' ? 1 : -1) * step;
    const width =
      event.key === 'Home' ? 0 : event.key === 'End' ? 1000 : currentChromeWidths()[kind] + change;
    safely(saveRailWidth(kind, width));
  },
  true,
);
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
  return `<header class="panel-header"><button type="button" id="panel-chooser" class="panel-chooser" aria-label="${esc(title)} · Switch browser panel" aria-haspopup="menu" aria-expanded="false" data-library-chooser>${icon(symbol)}<span id="panel-title" tabindex="-1">${title}</span>${icon('down')}</button>${ui.panel === 'ai' ? button('ui:ai-reset', 'New conversation', 'plus') : ''}${button('ui:panel-close', 'Close panel', 'close', 'data-key="panel-close"')}</header>`;
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
  element.hidden = !ui.panel && !(ui.panelAnimationWidth > 0);
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
            ui.aiGrantedPages,
            ui.aiContextChanging,
            ui.aiGrantedPages.map((page) => state.tabs.find((tab) => tab.id === page.id)?.url),
            state.runtime?.aiConfigured,
            activeProfile()?.id,
          ]
        : [state[ui.panel === 'archive' ? 'archive' : ui.panel], ui.panelQuery, activeProfile()?.id];
  const signature = JSON.stringify([ui.panel, data]);
  if (!force && signature === ui.panelSignature) return;
  ui.panelSignature = signature;
  const scroll = $('.panel-body', element)?.scrollTop || 0;
  const sameAIProfile = ui.aiPanelProfile === activeProfile()?.id;
  const draft = sameAIProfile ? ($('#ai-question', element)?.value ?? ui.aiDraft) : ui.aiDraft;
  if (sameAIProfile && $('#ai-question', element)) ui.aiDraft = draft;
  const disclosures = new Map(
    $$('details', element).map((details) => [details.id || $('summary', details)?.textContent, details.open]),
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
  syncLibraryChooserAnchor();
  const body = $('.panel-body', element);
  if (body) body.scrollTop = scroll;
  const composer = $('#ai-question', element);
  if (draft !== undefined && composer && composer.value !== draft) composer.value = draft;
  for (const details of $$('details', element)) {
    const key = details.id || $('summary', details)?.textContent;
    if (disclosures.has(key)) details.open = disclosures.get(key);
  }
  for (const [id, value] of Object.entries(providerDraft)) {
    const field = $('#' + id, element);
    if (field) field.value = value;
  }
  syncAPIKeyRequirement();
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
  const records = profileItems(key).filter((item) =>
    `${item.title || item.name || item.filename || ''} ${item.url || ''}`.toLowerCase().includes(query),
  );
  if (!records.length) {
    if (query) return empty('search', 'No matches', 'Try a different title or address.');
    const messages = {
      history: ['history', 'No history yet', 'Pages you visit appear here.'],
      bookmarks: ['bookmark', 'No bookmarks yet', 'Use the star to save a page.'],
      archive: ['archive', 'No archived tabs', 'Closed tabs will appear here.'],
      downloads: ['download', 'No downloads yet', 'Files you download appear here.'],
    };
    return empty(...messages[key]);
  }
  if (key === 'downloads') return renderDownloads(records);
  return libraryGroups(records, (item) => {
    const timestamp = key === 'history' ? new Date(item.visitedAt) : null;
    const time =
      timestamp && !Number.isNaN(timestamp.getTime())
        ? timestamp.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
        : '';
    return `<div class="resource" data-resource-id="${esc(item.id)}">${favicon(item.url)}<button type="button" class="resource-main" id="library-item-${esc(item.id)}" data-action="${key === 'archive' ? 'tab:restore' : 'ui:open-url'}" data-id="${esc(item.id)}" data-url="${esc(item.url)}" title="${esc(item.url)}"><span class="resource-title">${esc(item.title || hostname(item.url))}</span><span class="resource-meta">${esc(hostname(item.url))}</span></button>${time ? `<time class="resource-time" datetime="${timestamp.toISOString()}">${esc(time)}</time>` : ''}<div class="resource-actions">${key === 'bookmarks' ? button('bookmark:delete', 'Remove bookmark', 'close', `data-id="${esc(item.id)}"`) : key === 'archive' ? button('tab:restore', 'Restore tab', 'undo', `data-id="${esc(item.id)}"`) : button('peek:open', 'Preview page', 'eye', `data-url="${esc(item.url)}"`)}</div></div>`;
  });
}
function libraryGroups(records, renderRow) {
  const groups = new Map();
  const timestamp = (item) => item.visitedAt || item.archivedAt || item.startedAt || item.createdAt || 0;
  for (const item of [...records].sort((a, b) => timestamp(b) - timestamp(a)).slice(0, 500)) {
    const date = timestamp(item) ? dateLabel(timestamp(item)) : 'Earlier';
    if (!groups.has(date)) groups.set(date, []);
    groups.get(date).push(item);
  }
  return [...groups]
    .map(
      ([label, items]) =>
        `<section class="library-group" aria-label="${esc(label)}"><h3 class="list-label">${esc(label)}<span>${items.length}</span></h3>${items.map(renderRow).join('')}</section>`,
    )
    .join('');
}
function renderDownloads(records) {
  if (!records.length) return empty('download', 'No downloads yet', 'Files you download appear here.');
  return libraryGroups(records, (file) => {
    const name = file.name || file.filename || 'Download';
    const status = file.state || file.status || 'progressing';
    const progress =
      Number(file.totalBytes) > 0 ? Math.round((Number(file.receivedBytes || 0) / file.totalBytes) * 100) : 0;
    const complete = status === 'completed';
    const paused = file.paused || status === 'paused';
    const running = ['progressing', 'paused'].includes(status);
    return `<div class="resource download-resource" data-resource-id="${esc(file.id)}"><span class="download-file">${icon('file')}</span><div class="grow"><div class="resource-title" title="${esc(name)}">${esc(name)}</div><div class="resource-meta">${esc(complete ? bytes(file.totalBytes || file.receivedBytes) : status === 'cancelled' ? 'Cancelled' : status === 'interrupted' ? 'Interrupted' : paused ? 'Paused' : `${bytes(file.receivedBytes || 0)}${file.totalBytes > 0 ? ' / ' + bytes(file.totalBytes) : ''}`)}</div>${running ? `<div class="download-progress"><progress max="100" value="${progress}" aria-label="Download progress"></progress></div>` : ''}</div><div class="resource-actions">${complete ? button('download:show', isMac ? 'Show in Finder' : 'Show in folder', 'folder', `data-id="${esc(file.id)}"`) : running ? button(`download:${paused ? 'resume' : 'pause'}`, paused ? 'Resume download' : 'Pause download', paused ? 'play' : 'pause', `data-id="${esc(file.id)}"`) : ''}${complete || running ? `<button type="button" class="icon-button" aria-label="Actions for ${esc(name)}" title="Download actions" id="download-menu-${esc(file.id)}" data-download-menu="${esc(file.id)}" aria-haspopup="menu" aria-expanded="false">${icon('more')}</button>` : ''}</div></div>`;
  });
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
function syncAPIKeyRequirement() {
  const endpoint = $('#ai-base-url');
  const key = $('#ai-api-key');
  if (!endpoint || !key) return;
  const value = endpoint.value.trim();
  const changed = value !== (ui.aiStatus?.baseUrl || '');
  const local = isLocalAPIEndpoint(value);
  key.required = !local && (changed || !ui.aiStatus?.configured);
  key.placeholder = local
    ? 'Optional for localhost'
    : changed
      ? 'New key required for this endpoint'
      : ui.aiStatus?.configured
        ? 'Leave blank to keep saved key'
        : 'Paste an API key';
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
    return `${common}<form id="api-provider-form" data-provider="${esc(provider)}" autocomplete="off"><label class="ai-credential-field" for="ai-api-key">API key<input id="ai-api-key" name="apiKey" type="password" autocomplete="off" spellcheck="false" placeholder="${local ? 'Optional for localhost' : connected ? 'Leave blank to keep saved key' : 'Paste an API key'}" ${connected || local ? '' : 'required'}></label>${provider === 'compatible' ? `<label class="ai-credential-field" for="ai-base-url">Base URL<input id="ai-base-url" name="baseUrl" type="url" value="${esc(status.baseUrl || '')}" placeholder="https://example.com/v1" autocomplete="off" spellcheck="false" required></label>` : ''}<label class="ai-credential-field" for="ai-api-model">Model<input id="ai-api-model" name="model" value="${esc(status.model || '')}" list="ai-model-list" placeholder="Model ID" autocomplete="off" spellcheck="false" required></label><datalist id="ai-model-list">${models.map((model) => `<option value="${esc(model.id)}">${esc(model.name || model.id)}</option>`).join('')}</datalist><div class="setting-field"><label for="ai-key-storage">Keep key</label><select id="ai-key-storage" name="storage">${selectOptions([...(status.storageAvailable !== false ? [['encrypted', 'Encrypted on this device']] : []), ['session', 'This session only']], status.credentialStorage === 'session' || status.storageAvailable === false ? 'session' : 'encrypted')}</select></div><div class="setting-actions"><button type="submit" class="primary" ${ui.aiConfiguring ? 'disabled' : ''}>Save connection</button>${connected ? secondary('ui:ai-test', 'Test connection', '', 'id="ai-test-connection"') : ''}${connected && !keyless ? secondary('ui:ai-disconnect', 'Remove key', '', 'id="ai-account-action"') : ''}</div></form>${status.storageAvailable == null ? '<p class="provider-note">Encrypted storage is checked when you save. Your operating system may ask for approval.</p>' : ''}<p class="provider-note">Uses your provider’s API billing.${status.credentialStorage === 'session' ? ' This key is cleared when Zacro quits.' : ''}</p>${status.storageNotice ? `<p class="provider-note">${esc(status.storageNotice)}</p>` : ''}${provider === 'compatible' ? '<p class="provider-note">Keys stay with their endpoint. Localhost can run without a key.</p>' : ''}`;
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
function renderCustomization() {
  const customSelect = (key, label, values, format) => {
    const current = state.settings[key];
    return settingSelect(
      key,
      label,
      values.some(([value]) => value === current) ? values : [...values, [current, format(current)]],
    );
  };
  return `<details class="layout-settings"><summary>Layout & motion</summary>${settingSelect(
    'tabDensity',
    'Tab spacing',
    [
      ['compact', 'Compact'],
      ['comfortable', 'Comfortable'],
    ],
  )}${customSelect(
    'pageGutter',
    'Page inset',
    [
      [4, '4px'],
      [8, '8px'],
      [12, '12px'],
      [16, '16px'],
      [20, '20px'],
    ],
    (value) => `${value}px`,
  )}${customSelect(
    'pageRadius',
    'Page corners',
    [
      [0, 'Square'],
      [8, 'Soft'],
      [12, 'Rounded'],
      [16, 'Rounder'],
      [20, 'Pillowy'],
    ],
    (value) => `${value}px`,
  )}${customSelect(
    'motionScale',
    'Motion',
    [
      [0.7, 'Quick'],
      [1, 'Balanced'],
      [1.25, 'Relaxed'],
      [1.4, 'Gentle'],
    ],
    (value) => `Custom · ${value}×`,
  )}${settingSelect('pinnedSleepMinutes', 'Sleep idle favorites', [
    [0, 'Never'],
    [5, 'After 5 minutes'],
    [10, 'After 10 minutes'],
    [20, 'After 20 minutes'],
    [30, 'After 30 minutes'],
    [60, 'After an hour'],
    [120, 'After 2 hours'],
  ])}<p class="provider-note">Active pages, media and unsaved edits stay awake.</p></details>`;
}
function archiveSelect(profile) {
  if (!profile) return '';
  const primary =
    state.profiles.find((item) => item.id === 'default' && !item.private) ||
    state.profiles.find((item) => !item.private);
  const inherited = profile.id !== primary?.id;
  const values = [
    [12, 'After 12 hours'],
    [24, 'After 24 hours'],
    [72, 'After 3 days'],
    [168, 'After 7 days'],
    [720, 'After 30 days'],
    [0, 'Never'],
  ];
  const current = inherited ? (profile.archiveAfterHours ?? 'inherit') : state.settings.archiveAfterHours;
  if (inherited) {
    const hours = state.settings.archiveAfterHours;
    values.unshift(['inherit', `Use default · ${hours ? `${hours} hours` : 'Never'}`]);
  }
  if (!values.some(([value]) => value === current)) values.push([current, `After ${current} hours`]);
  return `<label class="setting-field"><span>Archive Today tabs</span><select data-profile-archive="${esc(profile.id)}" aria-label="Archive Today tabs for ${esc(profile.name)}">${values.map(([value, label]) => `<option value="${value}" ${value === current ? 'selected' : ''}>${label}</option>`).join('')}</select></label>`;
}
function renderSettings() {
  const settings = state.settings;
  const profile = activeProfile();
  const defaultBrowser =
    isMac && state.runtime?.defaultBrowser?.supported
      ? `<div class="setting-field"><span>Default browser</span>${state.runtime.defaultBrowser.configured ? '<span class="muted">Zacro</span>' : secondary('ui:default-browser', 'Make default')}</div>`
      : '';
  return `<section class="setting-section"><h3>Appearance</h3>${defaultBrowser}${renderCustomization()}${settingSelect(
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
  ])}${archiveSelect(profile)}${settingSelect('sidebarWidth', 'Sidebar width', [
    [224, 'Compact'],
    [260, 'Comfortable'],
    [300, 'Spacious'],
    ...(![224, 260, 300].includes(settings.sidebarWidth)
      ? [[settings.sidebarWidth, `${settings.sidebarWidth}px`]]
      : []),
  ])}<label class="setting-toggle"><span>Restore session</span><input type="checkbox" data-setting="restoreSession" ${settings.restoreSession ? 'checked' : ''}></label><div class="setting-actions">${secondary('ui:edit-space', 'Customize Space', 'edit')}${secondary('ui:profiles', 'Profiles', 'user')}${secondary('ui:shortcuts', 'Shortcuts', 'keyboard')}</div></section><details class="setting-section" id="ai-settings"><summary>AI providers</summary>${renderAIConnection()}${settingSelect(
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
const aiIntentPrompts = {
  summarize:
    'Summarize this page in five concise points. Highlight the main conclusion, useful details, and any important caveats. Cite the page.',
  explain:
    'Explain the main ideas on this page in plain language. Define unfamiliar terms and distinguish what the page says from what it does not establish. Cite the page.',
  compare:
    'Compare these pages. Organize the key similarities, differences, tradeoffs, and missing information in a concise table. Cite each page and do not guess.',
  research: 'Research ',
};
function aiPageGrant(tab) {
  if (!tab || tab.profileId !== activeProfile()?.id || !/^https?:\/\//i.test(tab.url)) return null;
  return { id: tab.id, url: tab.url, title: tab.title || hostname(tab.url) };
}
function aiContextStale(pages = ui.aiGrantedPages) {
  return pages.some((page) => {
    const tab = state.tabs.find((tab) => tab.id === page.id);
    return !tab || tab.profileId !== activeProfile()?.id || tab.url !== page.url;
  });
}
function rememberAIDraft(value) {
  const composer = $('#ai-question');
  const sameProfile = ui.aiPanelProfile === activeProfile()?.id;
  if (value === undefined) value = (sameProfile ? composer?.value : undefined) ?? ui.aiDraft;
  ui.aiDraft = String(value || '').slice(0, 8000);
  if (sameProfile && composer && composer.value !== ui.aiDraft) composer.value = ui.aiDraft;
}
function prepareDisconnectedQuestion(question) {
  rememberAIDraft();
  const differentDraft = ui.aiDraft.trim() && ui.aiDraft.trim() !== question;
  if (
    question.length > 8000 ||
    (differentDraft && ui.aiSavedQuestions.length && ui.aiSavedQuestions[0] !== question)
  ) {
    openPanel('ai');
    openCommand('newtab', question);
    toast(
      question.length > 8000
        ? 'Shorten your question to 8,000 characters. It is still in the command bar.'
        : 'Review or discard the saved question first. Your new question is still in the command bar.',
    );
    return;
  }
  if (differentDraft) {
    if (!ui.aiSavedQuestions.includes(question)) ui.aiSavedQuestions.push(question);
  } else if (!ui.aiDraft.trim()) rememberAIDraft(question);
  openPanel('ai');
  renderAIUpdate(false);
  $('#ai-question')?.focus();
  toast(
    differentDraft
      ? 'Your unfinished draft was kept. The new question is saved above for review.'
      : 'Your question is ready. Connect an AI provider in Settings to send it.',
  );
}
async function setAIContext(kind, pages = [], { force = false } = {}) {
  const profile = activeProfile()?.id;
  if (activeProfile()?.private) {
    toast('Private pages cannot be shared with AI.');
    return false;
  }
  rememberAIDraft();
  const next = kind === 'research' ? [] : pages;
  if (!force && kind === ui.aiContext && JSON.stringify(next) === JSON.stringify(ui.aiGrantedPages))
    return true;
  const token = ++ui.aiContextSerial;
  ui.aiContextChanging = true;
  invalidateAIRequest();
  renderAIUpdate(false);
  try {
    await invoke('ai:reset');
    if (token !== ui.aiContextSerial || profile !== activeProfile()?.id) return false;
    ui.aiMessages = [];
    ui.aiSources = [];
    ui.aiContext = kind;
    ui.aiGrantedPages = next;
    ui.aiTabs = next.map((page) => page.id);
    return true;
  } finally {
    if (token === ui.aiContextSerial && profile === activeProfile()?.id) {
      ui.aiContextChanging = false;
      renderAIUpdate(false);
    }
  }
}
async function openAIIntent(intent, tabIds = []) {
  if (!Object.hasOwn(aiIntentPrompts, intent)) return;
  if (activeProfile()?.private) {
    toast('AI is unavailable in private browsing.');
    return;
  }
  if (ui.aiBusy || ui.aiSubmitting) {
    toast('Stop the current response before changing context.');
    return;
  }
  if (intent === 'compare' && !tabIds.length) {
    showTabSelection({ intent });
    return;
  }
  const pages = (tabIds.length ? tabIds.map((id) => state.tabs.find((tab) => tab.id === id)) : [activeTab()])
    .map(aiPageGrant)
    .filter(Boolean);
  if (intent !== 'research' && (!pages.length || (intent === 'compare' && pages.length < 2))) {
    toast(
      intent === 'compare'
        ? 'Select at least two readable pages to compare.'
        : 'Open a web page or text PDF first.',
    );
    return;
  }
  if (
    !(await setAIContext(intent === 'research' ? 'research' : intent === 'compare' ? 'tabs' : 'page', pages))
  )
    return;
  openPanel('ai');
  // A prepared action must not silently erase an unfinished question.
  if (!ui.aiDraft.trim()) rememberAIDraft(aiIntentPrompts[intent]);
  else toast('Context updated. Your unfinished question was kept.');
  $('#ai-question')?.focus();
}
function aiTurnContext(message) {
  const request = message.request;
  if (!request) return '';
  return request.pages.length
    ? request.pages.map((page) => page.title || hostname(page.url)).join(' · ')
    : request.research
      ? 'Web research · no page text'
      : 'Chat · no page text';
}
function renderAnswer(message) {
  const text = String(message.text || '');
  const format = (raw) => {
    const parts = [];
    const expression = /\[([^\]\n]{1,200})\]\((https?:\/\/[^\s)]+)\)/g;
    let match,
      last = 0;
    while ((match = expression.exec(raw))) {
      parts.push(formatPlain(raw.slice(last, match.index)));
      parts.push(
        `<button type="button" class="text-button" data-action="ui:open-url" data-url="${esc(match[2])}">${esc(match[1])}</button>`,
      );
      last = match.index + match[0].length;
    }
    parts.push(formatPlain(raw.slice(last)));
    return parts.join('');
  };
  const formatPlain = (raw) =>
    esc(raw)
      .replace(/`([^`\n]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
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
  const locked = ui.aiBusy || ui.aiSubmitting || ui.aiContextChanging;
  const stale = aiContextStale();
  let body;
  if (!messages.length) {
    body = `<div class="ai-welcome">${icon('sparkle')}<h3>${privateSession ? 'Private session' : 'Understand what you’re browsing'}</h3><p>${privateSession ? 'AI is unavailable in private browsing.' : 'Choose a starting point and review your question and context before sending.'}</p>${
      !privateSession
        ? `<div class="ai-intents">${[
            ['summarize', 'Summarize page', 'file'],
            ['explain', 'Explain page', 'sparkle'],
            ['compare', 'Compare tabs', 'split'],
            [
              'research',
              ui.aiStatus?.researchSupported === false ? 'Start a chat' : 'Research a topic',
              'search',
            ],
          ]
            .map(
              ([intent, label, symbol]) =>
                `<button type="button" class="ai-intent prompt-suggestion" data-action="ui:ai-intent" data-intent="${intent}" ${locked ? 'disabled' : ''}>${icon(symbol)}${label}${icon('arrow')}</button>`,
            )
            .join(
              '',
            )}</div><p class="ai-empty-note">These actions prepare a question. Nothing is shared until you send.</p>`
        : primary('ui:spaces', 'Switch profile', 'user')
    }</div>`;
  } else {
    body = messages
      .map((message, index) => {
        const questionIndex =
          message.role === 'user'
            ? index
            : messages.slice(0, index).findLastIndex((item) => item.role === 'user');
        const actions = [];
        if (message.role === 'user' && message.request)
          actions.push(
            secondary(
              'ui:ai-edit',
              'Edit question',
              'edit',
              `data-index="${index}" ${locked ? 'disabled' : ''}`,
            ),
          );
        if (message.role === 'assistant' && message.text && !message.error && !message.streaming)
          actions.push(secondary('ui:ai-copy', 'Copy answer', 'copy', `data-index="${index}"`));
        if ((message.error || message.incomplete) && questionIndex >= 0 && messages[questionIndex]?.request)
          actions.push(
            secondary(
              'ui:ai-retry',
              'Retry question',
              'reload',
              `data-index="${questionIndex}" ${locked ? 'disabled' : ''}`,
            ),
          );
        return `<article class="message ${message.role}" data-message-index="${index}"><div class="message-role">${message.role === 'user' ? 'You' : message.error ? 'Couldn’t finish' : 'Zacro'}</div>${message.request ? `<p class="ai-turn-context" title="${esc(message.request.pages.map((page) => page.url).join('\n'))}">${icon(message.request.pages.length ? 'file' : 'globe')}${esc(aiTurnContext(message))}</p>` : ''}<div class="message-content ${message.error ? 'danger' : ''}">${message.role === 'assistant' ? renderAnswer(message) : esc(message.text)}</div>${message.warning ? `<p class="provider-note danger">${esc(message.warning)}</p>` : ''}${message.sharedTabs?.length ? `<p class="provider-note">Read: ${esc(message.sharedTabs.map((tab) => (tab.title || tab.url) + (tab.truncated ? ' (partial text)' : '') + (tab.pdf ? ' · PDF text' : '')).join(', '))}</p>` : ''}${message.unreadable?.length ? `<p class="provider-note">Couldn’t read: ${esc(message.unreadable.map((tab) => `${tab.title || 'Page'} — ${tab.reason || 'unavailable'}`).join('; '))}</p>` : ''}${message.sources?.length ? `<div class="source-list">${message.sources.map((source, i) => `<button type="button" class="source-item" data-action="ui:citation" data-id="${esc(source.tabId || '')}" data-url="${esc(source.url)}" title="${esc(source.url)}"><span class="source-index">${i + 1}</span><span class="grow truncate">${esc(source.title || hostname(source.url))}</span>${icon('external')}</button>`).join('')}</div>` : ''}${message.searchUrl ? `<button type="button" class="text-button" data-action="ui:open-url" data-url="${esc(message.searchUrl)}">${icon('search')}Open ordinary search results</button>` : ''}${actions.length ? `<div class="ai-message-actions">${actions.join('')}</div>` : ''}</article>`;
      })
      .join('');
  }
  const savedQuestions =
    !privateSession && ui.aiSavedQuestions.length
      ? `<details class="ai-saved-questions"><summary>Saved questions (${ui.aiSavedQuestions.length})</summary><p class="provider-note">Review a saved question in the composer. Your current draft will be kept here.</p>${ui.aiSavedQuestions.map((question, index) => `<div class="ai-saved-question"><p class="message-content">${esc(question)}</p><div class="ai-message-actions">${secondary('ui:ai-review-saved', 'Review saved question', 'edit', `data-index="${index}" ${locked ? 'disabled' : ''}`)}${secondary('ui:ai-discard-saved', 'Discard saved question', 'trash', `data-index="${index}"`)}</div></div>`).join('')}</details>`
      : '';
  return `<div class="panel-body conversation" id="conversation">${savedQuestions}${body}${ui.aiBusy ? `<div class="ai-progress" role="status"><span class="spinner"></span>${esc(ui.aiProgress || 'Looking into it…')}</div>` : ''}</div>${
    !privateSession
      ? `<div class="ai-footer" id="ai-footer">${!configured ? `<div class="row between"><span class="small muted">Connect to send your question.</span>${secondary('ui:ai-connect', ui.aiStatus?.loginPending || ui.aiSigningIn ? 'Continue sign-in' : 'Connect AI', 'user', 'id="ai-reconnect"')}</div>` : ''}${ui.aiSources.length && !ui.aiBusy ? `<button type="button" class="secondary ai-source-action" id="ai-open-sources" data-action="ai:open-sources">${icon('external')}Open sources <kbd>${shortcut('Mod+Enter')}</kbd></button>` : ''}<div class="ai-context" id="ai-context-controls">${icon('shield')}<label for="ai-context" class="sr-only">Content to share</label><select id="ai-context" ${ui.aiContextChanging || ui.aiSubmitting ? 'disabled' : ''}>${selectOptions(
          [
            [
              'research',
              ui.aiStatus?.researchSupported === false
                ? 'Chat · no page sharing'
                : 'Web research · no page sharing',
            ],
            ['page', 'One page'],
            ['tabs', `Selected tabs${ui.aiTabs.length ? ' (' + ui.aiTabs.length + ')' : ''}`],
          ],
          ui.aiContext,
        )}</select>${ui.aiContext === 'tabs' ? button('ui:ai-select-tabs', 'Choose tabs', 'plus', locked ? 'disabled' : '', 'small-button') : ''}${ui.aiContext !== 'research' ? button('ui:ai-clear-context', 'Clear shared context and conversation', 'close', locked ? 'disabled' : '', 'small-button') : ''}</div>${
          ui.aiContext !== 'research'
            ? `<div class="ai-context-chips" aria-label="Pages selected for sharing">${ui.aiGrantedPages.map((page) => `<div class="ai-context-chip ${aiContextStale([page]) ? 'stale' : ''}" data-context-id="${esc(page.id)}" title="${esc(page.url)}"><span class="grow truncate"><strong>${esc(page.title)}</strong><small>${esc(hostname(page.url))}${aiContextStale([page]) ? ' · page changed' : ''}</small></span>${button('ui:ai-remove-context', `Remove ${page.title} from context`, 'close', `data-id="${esc(page.id)}" ${locked ? 'disabled' : ''}`, 'small-button')}</div>`).join('')}</div><p class="provider-note" id="ai-sharing">On send, readable page or PDF text goes to ${esc(aiProviderName())}. Forms and passwords are excluded.</p>${stale ? `<p class="provider-note danger" role="status">A selected page changed or closed. ${secondary('ui:ai-refresh-context', 'Review pages again', '', locked ? 'disabled' : '')}</p>` : ''}`
            : `<p class="provider-note" id="ai-sharing">${!configured ? 'Web research depends on your connection.' : ui.aiStatus?.researchSupported === false ? 'No web search on this connection.' : 'Searches the web for supporting sources.'} No open-page text is shared.</p>`
        }<form id="ai-form" class="ai-composer"><textarea id="ai-question" name="question" rows="2" maxlength="8000" placeholder="${messages.length ? 'Ask a follow-up…' : 'Ask a question…'}" aria-label="Ask Zacro" aria-describedby="ai-sharing ai-help">${esc(ui.aiDraft)}</textarea>${ui.aiBusy ? button('ai:cancel', 'Stop response', 'stop', 'id="ai-submit"') : '<button type="submit" class="primary" id="ai-submit" aria-label="Send question" ' + (configured && !locked && !stale ? '' : 'disabled') + '>' + icon('arrow') + '</button>'}</form><p class="ai-help" id="ai-help">${configured ? 'Enter to send' : 'Connect AI to send'} · Shift + Enter for a new line. Check sources.</p></div>`
      : ''
  }`;
}
function openPanel(panel, { refreshStatus = true } = {}) {
  if (!panelNames[panel]) return;
  closeLibraryChooser();
  cancelRailResize();
  interruptSpaceScroll();
  if (ui.dialog) closeDialog();
  const start = currentChromeWidths();
  if (!ui.panel || !$('#side-panel').contains(document.activeElement)) ui.panelReturn = focusDescriptor();
  ui.panelMotion = (ui.panelMotion || 0) + 1;
  $('#side-panel')
    .getAnimations()
    .forEach((animation) => animation.cancel());
  ui.panel = panel;
  ui.lastPanel = panel;
  ui.panelQuery = '';
  ui.panelSignature = '';
  animateChrome(start);
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
  closeLibraryChooser();
  cancelRailResize();
  if (!ui.panel) return;
  const start = currentChromeWidths();
  ui.panelMotion = (ui.panelMotion || 0) + 1;
  $('#side-panel')
    .getAnimations()
    .forEach((animation) => animation.cancel());
  const focus = ui.panelReturn;
  ui.panel = null;
  ui.panelSignature = '';
  ui.panelReturn = null;
  animateChrome(start);
  restoreFocus(focus);
  maybeOpenBlankPalette();
}
function openDialog(kind, html, { title, focus } = {}) {
  closeLibraryChooser();
  cancelRailResize();
  // The native page snapshot and its clipped shell frame must use the same
  // settled bounds, even when a shortcut interrupts a moving chrome rail.
  finishChromeMotion();
  stopShortcutRecording();
  if (ui.themePreview) {
    ui.themePreview = null;
    previewWindowMaterial(null);
    setTheme();
  }
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
  if (ui.themePreview) {
    ui.themePreview = null;
    previewWindowMaterial(null);
    setTheme();
  }
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
  if (ui.dialog === 'onboarding') {
    safely(finishOnboarding());
    return;
  }
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
        return `<div class="space-option-wrapper"><button type="button" class="space-option ${space.id === state.activeSpaceId ? 'current' : ''}" data-action="ui:switch-space" data-id="${esc(space.id)}"><span class="space-emblem">${icon(space.icon || 'circle')}</span><span class="grow"><div class="space-option-name">${esc(space.name)}</div><div class="space-option-profile">${esc(profile?.name)}${profile?.private ? ' · Private' : ''} · ${state.tabs.filter((t) => t.spaceId === space.id).length} tabs</div></span>${space.id === state.activeSpaceId ? icon('check') : ''}</button><div class="space-option-actions">${button('ui:edit-space', 'Edit Space', 'edit', `data-id="${esc(space.id)}"`)}${button('ui:delete-space', 'Delete Space', 'trash', `data-id="${esc(space.id)}"`)}</div></div>`;
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
  const theme = { secondaryColor: '#b695b8', gradient: 50, grain: 0, opacity: 100, blur: 0, ...space?.theme };
  const range = (key, label, min, max, suffix = '%') =>
    `<label class="theme-range"><span>${label}<output data-theme-output="${key}">${theme[key]}${suffix}</output></span><input type="range" name="theme-${key}" min="${min}" max="${max}" value="${theme[key]}" aria-label="${label}"></label>`;
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
      `<input type="hidden" name="space-icon" value="${esc(space?.icon || 'circle')}"><input id="space-icon-search" type="search" placeholder="Find an icon" aria-label="Find a Space icon" autocomplete="off"><div class="space-icon-options" role="group" aria-label="Space icon">${spaceIcons.map((name) => `<button type="button" data-action="ui:space-icon" data-icon="${name}" aria-label="${name} icon" title="${name}" aria-pressed="${(space?.icon || 'circle') === name}">${icon(name)}</button>`).join('')}</div><div class="theme-preview-tile" aria-hidden="true"><div class="theme-preview-sidebar">${icon(space?.icon || 'circle')}<i></i><i></i><i></i></div><div class="theme-preview-page"></div><span>Preview</span></div><div class="field"><span>Space color</span><div class="color-options" role="group" aria-label="Space color">${colors.map(([name, color]) => `<button type="button" class="color-option swatch-${name} ${ui.selectedColor === color ? 'selected' : ''}" data-action="ui:color" data-color="${color}" aria-label="${name}" aria-pressed="${ui.selectedColor === color}"></button>`).join('')}</div></div><div class="theme-colors"><label>Primary<input type="color" name="theme-color" value="${ui.selectedColor}" aria-label="Primary color"></label><label>Secondary<input type="color" name="theme-secondaryColor" value="${theme.secondaryColor}" aria-label="Secondary color"></label></div><details class="theme-material"><summary>Gradient & texture</summary>${range('gradient', 'Color blend', 0, 100)}${range('grain', 'Grain', 0, 200)}</details><details class="theme-material"><summary>Glass & transparency</summary>${range('opacity', 'Window tint opacity', 0, 100)}<input type="hidden" name="theme-blur" value="${theme.blur}"></details>`,
    space ? 'Save changes' : 'Create Space',
    async (data, context) => {
      if (!context.isCurrent()) return;
      await invoke(space ? 'space:update' : 'space:create', {
        ...(space ? { id: space.id } : {}),
        name: data.get('name'),
        color: ui.selectedColor,
        icon: data.get('space-icon'),
        theme: readSpaceTheme(),
        ...(!space ? { profileId: data.get('profileId') } : {}),
      });
      if (!context.isCurrent()) return;
      if (!context.close()) return;
    },
  );
  $('.dialog').classList.add('space-theme-dialog');
  for (const swatch of $$('.color-option')) swatch.style.background = swatch.dataset.color;
  updateSpacePreview();
}
function readSpaceTheme() {
  const form = $('#modal-form');
  return {
    secondaryColor: form.elements['theme-secondaryColor'].value,
    ...Object.fromEntries(
      ['gradient', 'grain', 'opacity', 'blur'].map((key) => [
        key,
        Number(form.elements[`theme-${key}`].value),
      ]),
    ),
  };
}
function updateSpacePreview() {
  const form = $('#modal-form');
  if (!form?.elements['theme-color']) return;
  ui.selectedColor = form.elements['theme-color'].value;
  const previousOpacity = ui.themePreview?.theme.opacity;
  ui.themePreview = { color: ui.selectedColor, theme: readSpaceTheme() };
  if (previousOpacity !== ui.themePreview.theme.opacity) previewWindowMaterial(ui.themePreview.theme.opacity);
  for (const output of $$('[data-theme-output]', form)) {
    const key = output.dataset.themeOutput;
    output.value = `${ui.themePreview.theme[key]}${key === 'blur' ? 'px' : '%'}`;
  }
  for (const swatch of $$('.color-option', form)) {
    const selected = swatch.dataset.color === ui.selectedColor;
    swatch.classList.toggle('selected', selected);
    swatch.setAttribute('aria-pressed', selected);
  }
  const symbol = form.elements['space-icon'].value;
  $('.theme-preview-sidebar > svg')?.replaceWith(
    document.createRange().createContextualFragment(icon(symbol)),
  );
  setTheme();
}
document.addEventListener('input', (event) => {
  if (event.target.name?.startsWith('theme-')) updateSpacePreview();
  if (event.target.id === 'space-icon-search') {
    const query = event.target.value.trim().toLowerCase();
    for (const option of $$('.space-icon-options button'))
      option.hidden = !option.dataset.icon.includes(query);
  }
});
function showProfiles() {
  openDialog(
    'profiles',
    `<div class="dialog-header"><h2>Browser profiles</h2>${button('ui:dialog-close', 'Close', 'close')}</div><div class="dialog-body"><p class="dialog-description">Each profile keeps its accounts, cookies, history, and extensions separate.</p>${state.profiles.map((profile) => `<div class="profile-option"><div class="row"><span class="profile-avatar">${profile.private ? icon('shield') : esc(profile.name.slice(0, 1).toUpperCase())}</span><div class="grow"><strong>${esc(profile.name)}</strong><div class="profile-caption">${profile.private ? 'Private · cleared when closed' : 'Persistent profile'} · ${state.spaces.filter((s) => s.profileId === profile.id).length} Spaces</div></div>${button('ui:delete-profile', 'Delete profile', 'trash', `data-id="${esc(profile.id)}"`)}</div>${archiveSelect(profile)}</div>`).join('')}<div class="space-manager-actions">${primary('ui:new-profile', 'New profile', 'plus')}${secondary('ui:new-private', 'Private session', 'shield')}</div></div>`,
    { title: 'Browser profiles' },
  );
}
function showMenu() {
  const action = (name, label, symbol, key = '') =>
    `<button type="button" class="context-action" data-action="${name}">${icon(symbol)}${label}${key ? `<kbd>${key}</kbd>` : ''}</button>`;
  openPopover(
    'menu',
    `<div class="dialog-body">${action('ui:new-tab', 'New tab', 'plus', shortcutFor('command-palette', 'Mod+T'))}${action('ui:new-private', 'New private session', 'shield')}${action('ui:spaces', 'Spaces & profiles', 'user')}<hr class="context-separator">${action('ui:find', 'Find on page', 'search', shortcutFor('find', 'Mod+F'))}${action('ui:zoom-in', 'Zoom in', 'plus', shortcut('Mod+='))}${action('ui:zoom-out', 'Zoom out', 'minimize', shortcut('Mod+−'))}${action('ui:zoom-reset', 'Reset zoom', 'monitor', shortcut('Mod+0'))}${action('ui:print', 'Print page', 'print', shortcutFor('print', 'Mod+P'))}${action('ui:devtools', 'Developer tools', 'terminal')}<hr class="context-separator">${action('ui:extensions', 'Extensions', 'extension')}${action('ui:settings', 'Settings', 'settings')}${action('ui:shortcuts', 'Keyboard shortcuts', 'keyboard')}${action('ui:onboarding', 'Welcome tour', 'sparkle')}${action('ui:home-page', 'Home page', 'monitor')}${action('ui:about', 'About Zacro', 'info')}</div>`,
    { title: 'Browser menu', anchor: $('[data-key="page-menu"]') },
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
    `<div class="dialog-body">${action('ui:bookmark', saved ? 'Remove bookmark' : 'Bookmark this page', 'star', `data-key="bookmark" aria-pressed="${saved}" ${blank ? 'disabled' : ''}`, shortcutFor('bookmark', 'Mod+D'))}${action('ui:split', state.runtime?.splitTabId ? 'Close split view' : 'Split view', 'split', 'data-key="split"')}${action('ui:find', 'Find on page', 'search', blank ? 'disabled' : '', shortcutFor('find', 'Mod+F'))}${action('ui:print', 'Print page', 'print', blank ? 'disabled' : '', shortcutFor('print', 'Mod+P'))}<hr class="context-separator"><div class="menu-zoom" aria-label="Page zoom">${button('ui:zoom-out', 'Zoom out', 'minimize')}${action('ui:zoom-reset', `${Math.round((state.runtime?.page?.zoom || 1) * 100)}%`, 'monitor')}${button('ui:zoom-in', 'Zoom in', 'plus')}</div><hr class="context-separator">${action('external:open', 'Open in default browser', 'external', `data-key="external-page" data-url="${esc(blank ? '' : tab.url)}" ${blank ? 'disabled' : ''}`)}${action('ui:menu', 'Browser menu', 'more', '', shortcutFor('browser-menu', 'F10'))}</div>`,
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
  const external = $('[data-key="external-page"]', root);
  external.disabled = blank;
  external.dataset.url = blank ? '' : tab.url;
  $('[data-action="ui:zoom-reset"] span', root).textContent =
    `${Math.round((state.runtime?.page?.zoom || 1) * 100)}%`;
}
function showLibrary() {
  showLibraryChooser($('[data-key="library"]'));
}
function syncLibraryChooserAnchor() {
  if (!ui.libraryMenuOpen) return;
  const descriptor = ui.libraryMenuReturn;
  const anchor =
    (descriptor?.id && document.getElementById(descriptor.id)) ||
    (descriptor?.key && $(`[data-key="${CSS.escape(descriptor.key)}"]`)) ||
    (descriptor?.element?.isConnected && descriptor.element);
  if (!anchor) return closeLibraryChooser();
  ui.libraryMenuReturn = focusDescriptor(anchor);
  anchor.setAttribute('aria-expanded', 'true');
}
function closeLibraryChooser({ restore = false } = {}) {
  const menu = $('#library-menu');
  const opener = ui.libraryMenuReturn;
  ui.libraryMenuOpen = false;
  ui.libraryMenuReturn = null;
  if (menu) {
    if (menu.matches(':popover-open')) menu.hidePopover();
    menu.remove();
  }
  for (const control of $$('[data-library-chooser],[data-download-menu],[data-key="library"]'))
    control.setAttribute('aria-expanded', 'false');
  if (restore && opener) restoreFocus(opener);
}
function openLibraryChooser(anchor, html, label = 'Library') {
  if (!anchor) return;
  if (ui.libraryMenuOpen && ui.libraryMenuReturn?.element === anchor) {
    closeLibraryChooser({ restore: true });
    return;
  }
  closeLibraryChooser();
  // This top-layer menu stays inside its chrome rail. Native web contents keep
  // rendering at their original scale: no overlay IPC or page snapshot is used.
  finishChromeMotion();
  interruptSpaceScroll();
  ui.libraryMenuOpen = true;
  if (ui.dialog) closeDialog({ restore: false });
  const menu = document.createElement('div');
  menu.id = 'library-menu';
  menu.className = 'library-menu';
  menu.setAttribute('popover', 'auto');
  menu.setAttribute('role', 'menu');
  menu.setAttribute('aria-label', label);
  menu.innerHTML = html;
  document.body.append(menu);
  ui.libraryMenuReturn = focusDescriptor(anchor);
  anchor.setAttribute('aria-expanded', 'true');
  const rail = anchor.closest('#side-panel') || $('#sidebar');
  const bounds = rail.getBoundingClientRect();
  const control = anchor.getBoundingClientRect();
  const edge = 8;
  menu.style.width = `${Math.max(168, Math.min(244, bounds.width - edge * 2))}px`;
  menu.style.maxHeight = `${innerHeight - edge * 2}px`;
  menu.showPopover();
  const rect = menu.getBoundingClientRect();
  menu.style.left = `${Math.max(edge, Math.min(control.left, bounds.right - rect.width - edge))}px`;
  const below = control.bottom + 5;
  menu.style.top = `${Math.max(edge, Math.min(below + rect.height > innerHeight - edge ? control.top - rect.height - 5 : below, innerHeight - rect.height - edge))}px`;
  menu.addEventListener('click', (event) => {
    if (event.target.closest('[data-action]')) closeLibraryChooser({ restore: true });
  });
  menu.addEventListener('toggle', (event) => {
    if (event.newState === 'closed' && $('#library-menu') === menu) {
      closeLibraryChooser();
      maybeOpenBlankPalette();
    }
  });
  motion(
    menu,
    [
      { opacity: 0, transform: 'translateY(3px)' },
      { opacity: 1, transform: 'translateY(0)' },
    ],
    120,
  );
  ($('[aria-checked="true"]', menu) || $('button', menu))?.focus({ preventScroll: true });
}
function showLibraryChooser(anchor) {
  const item = (panel) => {
    const [symbol, label] = panelNames[panel];
    const shortcutId = panel === 'settings' ? 'preferences' : panel;
    const key = shortcutId ? shortcutFor(shortcutId) : '';
    return `<button type="button" class="context-action" role="menuitemradio" aria-label="${esc(label)}" aria-checked="${ui.panel === panel}" data-action="ui:panel" data-panel="${panel}" data-key="panel-${panel}">${icon(symbol)}<span>${label}</span>${key ? `<kbd aria-hidden="true">${esc(key)}</kbd>` : ''}${ui.panel === panel ? `<span class="menu-check">${icon('check')}</span>` : ''}</button>`;
  };
  openLibraryChooser(
    anchor,
    ['bookmarks', 'history', 'downloads', 'archive'].map(item).join('') +
      '<hr class="context-separator" role="separator">' +
      ['settings', 'extensions', 'ai'].map(item).join(''),
  );
}
function showDownloadMenu(anchor, id) {
  const file = profileItems('downloads').find((item) => item.id === id);
  if (!file) return;
  const item = (action, label, symbol) =>
    `<button type="button" class="context-action" role="menuitem" data-action="${action}" data-id="${esc(id)}">${icon(symbol)}<span>${label}</span></button>`;
  const complete = (file.state || file.status) === 'completed';
  openLibraryChooser(
    anchor,
    complete
      ? item('ui:download-rename', 'Rename', 'edit') +
          item(
            'ui:download-suggest',
            ui.downloadSuggestions.has(id) ? 'Review name' : 'Suggest name',
            'sparkle',
          ) +
          (file.originalName || file.previousPath || file.previousName
            ? item('download:undo', 'Undo rename', 'undo')
            : '')
      : item('download:cancel', 'Cancel download', 'close'),
    'Download actions',
  );
}
document.addEventListener(
  'click',
  (event) => {
    const chooser = event.target.closest('[data-library-chooser]');
    const download = event.target.closest('[data-download-menu]');
    if (!chooser && !download) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (chooser) showLibraryChooser(chooser);
    else showDownloadMenu(download, download.dataset.downloadMenu);
  },
  true,
);
document.addEventListener(
  'keydown',
  (event) => {
    const menu = $('#library-menu');
    if (!menu || !ui.libraryMenuOpen || event.isComposing) return;
    const items = $$('button:not(:disabled)', menu);
    const current = items.indexOf(document.activeElement);
    if (['Escape', 'Tab'].includes(event.key)) {
      closeLibraryChooser({ restore: true });
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
      return;
    }
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      const next =
        event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? items.length - 1
            : (current + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items[next]?.focus({ preventScroll: true });
      items[next]?.scrollIntoView({ block: 'nearest' });
    } else if (
      event.key.length === 1 &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey &&
      event.key !== ' '
    ) {
      const ordered = [...items.slice(current + 1), ...items.slice(0, current + 1)];
      const next = ordered.find((item) =>
        $('span', item)?.textContent.toLowerCase().startsWith(event.key.toLowerCase()),
      );
      if (next) {
        event.preventDefault();
        event.stopImmediatePropagation();
        next.focus({ preventScroll: true });
        next.scrollIntoView({ block: 'nearest' });
      }
    }
  },
  true,
);
window.addEventListener('blur', () => closeLibraryChooser());
window.addEventListener('resize', () => closeLibraryChooser());
document.addEventListener('dragstart', () => closeLibraryChooser(), true);
document.addEventListener(
  'keydown',
  (event) => {
    if (
      ui.dialog ||
      ui.libraryMenuOpen ||
      event.isComposing ||
      event.ctrlKey ||
      event.metaKey ||
      event.altKey
    )
      return;
    const search = event.target.id === 'panel-search';
    const row = event.target.closest?.('#side-panel .resource-main');
    if (
      (!search && !row) ||
      (search && event.key !== 'ArrowDown') ||
      (!search && !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key))
    )
      return;
    const items = $$('#side-panel .resource-main');
    if (!items.length) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const index = items.indexOf(row);
    if (event.key === 'ArrowUp' && index === 0) $('#panel-search')?.focus();
    else {
      const next =
        search || event.key === 'Home'
          ? 0
          : event.key === 'End'
            ? items.length - 1
            : Math.max(0, Math.min(items.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)));
      items[next].focus({ preventScroll: true });
      items[next].scrollIntoView({ block: 'nearest' });
    }
  },
  true,
);
function toggleSidebar(fromPage = false) {
  closeLibraryChooser();
  cancelRailResize();
  interruptSpaceScroll();
  if (ui.dialog) closeDialog({ restore: false });
  if (!ui.sidebarHidden && effectiveSidebarHidden() && ui.panel) {
    closePanel();
    if (fromPage) safely(invoke('page:focus'));
    return;
  }
  const start = currentChromeWidths();
  ui.sidebarHidden = !ui.sidebarHidden;
  animateChrome(start);
  if (fromPage) safely(invoke('page:focus'));
  else $('[data-key="address"]')?.focus({ preventScroll: true });
}
function showSpaceMenu(id) {
  const space = state.spaces.find((item) => item.id === id && item.profileId === activeProfile()?.id);
  if (!space) return;
  const anchor = $(`.space-dot[data-id="${CSS.escape(id)}"]`);
  anchor?.focus({ preventScroll: true });
  const tab = activeTab();
  const canMove = tab?.spaceId !== id && tab?.profileId === space.profileId && tab?.url !== 'zacro://newtab';
  const onlySpace = state.spaces.filter((item) => item.profileId === space.profileId).length === 1;
  const action = (name, label, symbol, attributes = '') =>
    `<button type="button" class="context-action" data-action="${name}" data-id="${esc(id)}" ${attributes}>${icon(symbol)}${esc(label)}</button>`;
  openPopover(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(space.name)}</div>${
      id !== state.activeSpaceId ? action('ui:switch-space', 'Switch to Space', 'arrow') : ''
    }${action('ui:edit-space', 'Customize Space', 'settings')}${action('ui:rename-space', 'Rename Space', 'edit')}${
      canMove
        ? action('ui:space-move-tab', 'Move current tab here', 'folder', `data-source-tab="${esc(tab.id)}"`)
        : ''
    }<hr class="context-separator">${action('ui:new-space', 'New Space', 'plus')}${action(
      'ui:delete-space',
      'Delete Space',
      'trash',
      onlySpace ? 'disabled title="Keep at least one Space in this profile"' : '',
    )}</div>`,
    { title: 'Space actions', anchor },
  );
}
function showTabMenu(id) {
  const tab = state.tabs.find((t) => t.id === id);
  if (!tab) return;
  const action = (name, label, symbol) =>
    `<button type="button" class="context-action" data-action="${name}" data-id="${esc(id)}">${icon(symbol)}${esc(label)}</button>`;
  openPopover(
    'menu',
    `<div class="dialog-body"><div class="section-label truncate">${esc(tabLabel(tab))}</div>${action('ui:tab-pin', tab.pinned ? 'Unpin tab' : 'Pin tab', 'pin')}${action('ui:tab-favorite', tab.favorite ? 'Move to pinned tabs' : 'Add to Favorites', 'star')}${tab.pinned ? action('ui:tab-reset-pin', 'Reset to saved page', 'undo') + (!tab.closed && tab.url !== tab.pinnedUrl ? action('ui:tab-replace-pin', 'Replace pin with current page', 'edit') : '') : ''}<hr class="context-separator">${action('ui:tab-duplicate', 'Duplicate tab', 'copy')}${action('ui:tab-split', 'Open in split view', 'split')}${action('ui:tab-move', 'Move to Space or folder', 'folder')}${action('ui:tab-rename', 'Rename tab', 'edit')}${tab.pinned && state.runtime?.pages?.[id]?.loaded && id !== state.activeTabId ? action('ui:tab-sleep', 'Put to sleep', 'moon') : ''}<hr class="context-separator">${action('ui:tab-close', tab.pinned ? 'Close page · keep pin' : 'Close tab', 'close')}</div>`,
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
function showTabSelection({ intent } = {}) {
  const tabs = state.tabs.filter((tab) => aiPageGrant(tab));
  if (activeProfile()?.private) {
    toast('Private pages cannot be shared with AI.');
    return;
  }
  formDialog(
    'Ask selected tabs',
    `Choose ${intent === 'compare' ? 'two to six' : 'up to six'} pages. Their readable page or PDF text will be shared with ${aiProviderName()} only when you send a question.`,
    `<div class="tab-selector">${tabs.map((tab) => `<label class="tab-select-row"><input type="checkbox" name="tabId" value="${esc(tab.id)}" ${ui.aiTabs.includes(tab.id) ? 'checked' : ''}>${favicon(tab.url)}<span class="grow truncate" title="${esc(tab.url)}">${esc(tab.title || hostname(tab.url))}</span></label>`).join('') || '<p class="dialog-description">Open some pages first, then select the ones you want to share.</p>'}</div>`,
    'Use selected tabs',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const selected = data.getAll('tabId');
      if (!selected.length || (intent === 'compare' && selected.length < 2))
        throw new Error(
          intent === 'compare' ? 'Choose at least two pages to compare.' : 'Choose at least one page.',
        );
      if (selected.length > 6) throw new Error('Choose up to six tabs for one question.');
      const pages = selected
        .map((id) => aiPageGrant(state.tabs.find((tab) => tab.id === id)))
        .filter(Boolean);
      if (pages.length !== selected.length)
        throw new Error('A selected page closed. Choose the pages again.');
      if (!(await setAIContext('tabs', pages)) || !context.isCurrent()) return;
      if (!context.close()) return;
      openPanel('ai');
      if (intent && !ui.aiDraft.trim()) rememberAIDraft(aiIntentPrompts[intent]);
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
const onboardingSteps = [
  {
    title: 'A little space to think.',
    description: 'One command bar for websites, tabs, Spaces and actions.',
    symbol: 'search',
    shortcuts: ['command-palette', 'open-location'],
  },
  {
    title: 'Make room for the page.',
    description: 'Hide the sidebar whenever you need room. Bring it back just as easily.',
    symbol: 'sidebar',
    shortcuts: ['sidebar-toggle', 'focus-sidebar', 'focus-chrome'],
  },
  {
    title: 'Keep your place.',
    description: 'Jump between recent tabs, or move to a different Space.',
    symbol: 'layers',
    shortcuts: ['recent-tab', 'previous-space', 'next-space'],
  },
  {
    title: 'Keep the good ones close.',
    description:
      'Pins stay in their Space. Favorites follow you between Spaces. Close either to unload its page.',
    symbol: 'pin',
    shortcuts: ['pin-tab', 'close-tab', 'reopen-tab'],
  },
  {
    title: 'Make yourself at home.',
    description: 'Your themes, your shortcuts. You can revisit this tour from the browser menu.',
    symbol: 'settings',
    shortcuts: ['preferences', 'shortcuts'],
  },
];
function maybeOpenOnboarding() {
  if (
    ui.onboardingOffered ||
    state.settings.onboardingCompleted ||
    state.runtime?.onboardingEnabled === false
  )
    return;
  ui.onboardingOffered = true;
  showOnboarding();
}
function showOnboarding(step = 0) {
  ui.onboardingOffered = true;
  ui.onboardingStep = Math.max(0, Math.min(onboardingSteps.length - 1, Number(step) || 0));
  ui.shortcutError = '';
  const entry = onboardingSteps[ui.onboardingStep];
  const last = ui.onboardingStep === onboardingSteps.length - 1;
  openDialog(
    'onboarding',
    `<header class="onboarding-top"><span class="onboarding-brand">${mark}<span>Zacro</span></span><button type="button" class="text-button" data-action="ui:onboarding-finish">Skip tour</button></header><div class="onboarding-body"><div class="onboarding-scene" data-scene="${ui.onboardingStep}" aria-hidden="true"><div class="onboarding-mini-sidebar"><span></span><span></span><span></span><i></i></div><div class="onboarding-mini-page">${icon(entry.symbol)}<span></span><span></span></div></div><div class="onboarding-copy"><h2 id="onboarding-title">${esc(entry.title)}</h2><p>${esc(entry.description)}</p></div><div id="onboarding-shortcuts"></div><div class="onboarding-hint">Select any shortcut to make it yours.</div><div id="onboarding-status" class="shortcut-status" role="status" aria-live="polite"></div></div><footer class="onboarding-footer"><button type="button" class="text-button" data-action="ui:onboarding-back" ${ui.onboardingStep ? '' : 'disabled'}>Back</button><nav class="onboarding-progress" aria-label="Tour steps">${onboardingSteps.map((item, index) => `<button type="button" data-action="ui:onboarding-step" data-id="${index}" aria-label="Step ${index + 1}: ${esc(item.title)}" ${index === ui.onboardingStep ? 'aria-current="step"' : ''}></button>`).join('')}</nav><button type="button" class="primary" data-action="${last ? 'ui:onboarding-finish' : 'ui:onboarding-next'}">${last ? 'Start browsing' : 'Continue'}${icon('forward')}</button></footer>`,
    { title: 'Welcome to Zacro', focus: '[data-shortcut-record]' },
  );
  $('.dialog').classList.add('onboarding-dialog');
  $('.dialog').setAttribute('aria-labelledby', 'onboarding-title');
  renderOnboardingShortcuts();
}
function renderOnboardingShortcuts() {
  const root = $('#onboarding-shortcuts');
  if (!root) return;
  const selected = document.activeElement?.dataset?.shortcutRecord;
  root.innerHTML = onboardingSteps[ui.onboardingStep].shortcuts
    .map((id) => state.runtime?.shortcuts?.find((entry) => entry.id === id))
    .filter(Boolean)
    .map((entry) => {
      const recording = ui.recordingShortcut === entry.id;
      return `<div class="shortcut-row" data-shortcut-id="${esc(entry.id)}"><span class="grow">${esc(entry.label)}</span><button type="button" class="shortcut-key ${recording ? 'recording' : ''}" data-action="ui:shortcut-record" data-id="${esc(entry.id)}" data-shortcut-record="${esc(entry.id)}" aria-label="${esc(`Change shortcut for ${entry.label}`)}"><kbd>${recording ? 'Press keys…' : esc(entry.accelerator ? shortcut(entry.accelerator) : 'Unassigned')}</kbd></button>${button('ui:shortcut-reset', `Reset ${entry.label}`, 'undo', `data-id="${esc(entry.id)}" ${entry.customized ? '' : 'disabled'}`)}</div>`;
    })
    .join('');
  const status = $('#onboarding-status');
  status.textContent =
    ui.shortcutError ||
    (ui.recordingShortcut ? 'Press a combination. Escape cancels; Delete removes it.' : '');
  status.classList.toggle('danger', Boolean(ui.shortcutError));
  if (selected) $(`[data-shortcut-record="${CSS.escape(selected)}"]`, root)?.focus({ preventScroll: true });
}
async function finishOnboarding() {
  // Persist before dismissing: a storage failure leaves a visible, retryable tour.
  await invoke('settings:update', { values: { onboardingCompleted: true } });
  if (ui.dialog === 'onboarding') closeDialog();
}
function refreshShortcutEditor() {
  if (ui.dialog === 'shortcuts') renderShortcutRows();
  else if (ui.dialog === 'onboarding') renderOnboardingShortcuts();
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
  refreshShortcutEditor();
  $(`[data-shortcut-record="${CSS.escape(id)}"]`)?.focus();
  try {
    await invoke('shortcut:record', { active: true });
    if (ui.recordingShortcut !== id || !['shortcuts', 'onboarding'].includes(ui.dialog))
      await invoke('shortcut:record', { active: false });
  } catch (error) {
    stopShortcutRecording();
    ui.shortcutError = error.message;
    refreshShortcutEditor();
  }
}
function recordedAccelerator(event) {
  if (['Control', 'Meta', 'OS', 'Alt', 'AltGraph', 'Shift', 'Dead', 'Unidentified'].includes(event.key))
    return null;
  if (!isMac && event.metaKey) {
    ui.shortcutError = 'Windows-key combinations belong to Windows. Choose Control, Alt or a function key.';
    refreshShortcutEditor();
    return null;
  }
  const keys = [];
  if (isMac ? event.metaKey : event.ctrlKey) keys.push('Mod');
  if (isMac && event.ctrlKey) keys.push('Ctrl');
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
  ) {
    ui.shortcutError = 'That combination types a character on your keyboard. Try another shortcut.';
    refreshShortcutEditor();
    return null;
  }
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
  if (['shortcuts', 'onboarding'].includes(ui.dialog)) {
    refreshShortcutEditor();
    $(`[data-shortcut-record="${CSS.escape(id)}"]`)?.focus({ preventScroll: true });
  }
}
const commandSymbols = {
  'command-palette': 'plus',
  'open-location': 'search',
  'sidebar-toggle': 'sidebar',
  'focus-sidebar': 'sidebar',
  'reveal-tab': 'eye',
  'browser-menu': 'more',
  onboarding: 'sparkle',
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
  onboarding: 'welcome introduction tour help learn keyboard',
  'focus-sidebar': 'keyboard focus tabs sidebar navigate',
  'reveal-tab': 'show active current tab sidebar',
  'browser-menu': 'menu browser controls options',
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
  const results = catalog
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
  const extra = (id, label, symbol, keywords, run) =>
    results.push({
      id: `action:${id}`,
      kind: 'action',
      label,
      symbol,
      keywords,
      type: 'Action',
      priority: 5,
      run: () => {
        closeDialog({ restore: false });
        return run();
      },
    });
  extra(
    'space-theme',
    'Customize this Space',
    'sun',
    'color icon gradient grain transparency blur theme',
    () => showSpaceForm(state.activeSpaceId),
  );
  extra(
    'site-searches',
    'Manage Site Search',
    'search',
    'site search engines keyword shortcut custom website',
    () => {
      openCommand('newtab');
      showSiteSearches();
    },
  );
  if (currentTabs().some((item) => item.pinned && !item.favorite))
    extra(
      'reset-space-pins',
      'Reset pins in this Space',
      'undo',
      'reset space pinned tabs original saved urls',
      () => invoke('space:reset-pins', { id: state.activeSpaceId }),
    );
  if (real) {
    extra('pin-destination', 'Pin tab to…', 'pin', 'pin to space folder organize', () => {
      openCommand('newtab');
      showCommandDestinations(tab.id, true);
    });
    extra(
      'favorite-tab',
      tab.favorite ? 'Move favorite to this Space' : 'Favorite tab',
      'star',
      'favorite icon all spaces',
      () => invoke('tab:favorite', { id: tab.id, favorite: !tab.favorite }),
    );
    if (tab.pinned) {
      extra('reset-pin', 'Reset pinned tab', 'undo', 'reset tab original pinned saved url', () =>
        invoke('tab:reset-pin', { id: tab.id }),
      );
      if (tab.pinnedUrl !== tab.url)
        extra(
          'replace-pin',
          'Replace pin with current page',
          'pin',
          'replace original pinned saved url',
          () => invoke('tab:replace-pin', { id: tab.id }),
        );
    }
  }
  extra(
    'sleep-favorites',
    'Sleep unused favorites',
    'moon',
    'memory suspend unload idle pinned tabs',
    async () => {
      let count = 0;
      for (const pin of state.tabs.filter(
        (item) =>
          item.favorite &&
          item.profileId === activeProfile()?.id &&
          item.id !== state.activeTabId &&
          state.runtime?.pages?.[item.id]?.loaded,
      ))
        if ((await invoke('tab:sleep', { id: pin.id }))?.slept) count++;
      toast(
        count
          ? `${count} favorite${count === 1 ? '' : 's'} put to sleep.`
          : 'No idle favorites to sleep. Active pages and unsaved work stay awake.',
      );
    },
  );
  if (!activeProfile()?.private) {
    if (real) {
      extra('ai-summarize', 'Summarize this page', 'sparkle', 'AI summarize page article PDF', () =>
        openAIIntent('summarize', [tab.id]),
      );
      extra('ai-explain', 'Explain this page', 'book', 'AI explain understand page', () =>
        openAIIntent('explain', [tab.id]),
      );
    }
    extra('ai-compare', 'Compare pages', 'split', 'AI compare selected tabs sources', () =>
      openAIIntent('compare'),
    );
    extra('ai-research', 'Research a question', 'globe', 'AI research web question', () =>
      openAIIntent('research'),
    );
  }
  return results;
}

function pushCommandStep() {
  ui.commandTrail.push({
    query: ui.commandQuery,
    index: ui.commandIndex,
    filter: ui.commandFilter,
    context: ui.commandContext,
    siteSearch: ui.commandSiteSearch,
  });
  ui.commandQuery = '';
  ui.commandIndex = 0;
  ui.commandFilter = 'all';
  ui.commandContext = null;
  ui.commandSiteSearch = null;
}
function refreshCommandStep() {
  const input = $('#command-input');
  if (!input) return;
  input.value = ui.commandQuery;
  renderCommands();
  input.focus();
}
function backCommandStep() {
  const previous = ui.commandTrail.pop();
  if (!previous) return false;
  ui.commandQuery = previous.query;
  ui.commandIndex = previous.index;
  ui.commandFilter = previous.filter;
  ui.commandContext = previous.context;
  ui.commandSiteSearch = previous.siteSearch;
  refreshCommandStep();
  return true;
}
function enterCommandContext(title, options, ariaLabel = title) {
  pushCommandStep();
  ui.commandContext = { title, options, ariaLabel };
  refreshCommandStep();
}
function commandTask(id, label, symbol, run, description = '') {
  return { id, kind: 'action', label, symbol, description, type: '', run };
}
function closeAndRunCommand(run) {
  closeDialog({ restore: false });
  return run();
}
function showCommandDestinations(tabId, pin = false) {
  const tab = state.tabs.find((item) => item.id === tabId && item.profileId === activeProfile()?.id);
  if (!tab) return;
  enterCommandContext(pin ? 'Pin to…' : 'Move to…', () => {
    const fresh = state.tabs.find((item) => item.id === tabId && item.profileId === activeProfile()?.id);
    if (!fresh) return [];
    return state.spaces
      .filter((space) => space.profileId === fresh.profileId)
      .flatMap((space) => [
        { id: space.id, name: space.name, symbol: space.icon || 'layers', spaceId: space.id, folderId: null },
        ...state.folders
          .filter((folder) => folder.spaceId === space.id)
          .map((folder) => ({
            id: folder.id,
            name: folder.name,
            description: space.name,
            symbol: 'folder',
            spaceId: space.id,
            folderId: folder.id,
          })),
      ])
      .map((destination) =>
        commandTask(
          `destination:${destination.id}`,
          destination.name,
          destination.symbol,
          () =>
            closeAndRunCommand(() =>
              invoke('tab:move', {
                id: tabId,
                spaceId: destination.spaceId,
                folderId: destination.folderId,
                ...(pin ? { pinned: true, favorite: false } : {}),
              }),
            ),
          destination.description || '',
        ),
      );
  });
}
function showCommandResultActions(item) {
  if (!item || !['tab', 'history', 'bookmark'].includes(item.kind)) return false;
  const itemId = item.id;
  const tabId = item.kind === 'tab' ? itemId.slice(4) : null;
  enterCommandContext(
    item.label,
    () => {
      const tab = tabId
        ? state.tabs.find(
            (candidate) => candidate.id === tabId && candidate.profileId === activeProfile()?.id,
          )
        : null;
      if (tabId && !tab) return [];
      const url = tab?.url || item.url;
      const actions = [
        commandTask('result:open', tab ? 'Switch to tab' : 'Open page', 'forward', () => item.run()),
      ];
      if (url && url !== 'zacro://newtab') {
        actions.push(
          commandTask('result:newtab', 'Open in new tab', 'plus', () => commitNavigation(url, true)),
          commandTask('result:peek', 'Peek at page', 'eye', () =>
            closeAndRunCommand(() => invoke('peek:open', { url })),
          ),
          commandTask('result:copy', 'Copy address', 'copy', () =>
            closeAndRunCommand(async () => {
              await invoke('clipboard:write-text', { text: url });
              toast('Address copied.');
            }),
          ),
        );
      }
      if (tab) {
        if (tab.spaceId === state.activeSpaceId && tab.id !== state.activeTabId && url !== 'zacro://newtab')
          actions.push(
            commandTask('result:split', 'Open in split view', 'split', () =>
              closeAndRunCommand(() => invoke('split:toggle', { id: tab.id })),
            ),
          );
        actions.push(
          commandTask('result:pin', tab.pinned ? 'Unpin tab' : 'Pin tab', 'pin', () =>
            closeAndRunCommand(() => invoke('tab:pin', { id: tab.id })),
          ),
          commandTask(
            'result:favorite',
            tab.favorite ? 'Move favorite to this Space' : 'Favorite tab',
            'star',
            () => closeAndRunCommand(() => invoke('tab:favorite', { id: tab.id, favorite: !tab.favorite })),
          ),
          commandTask('result:move', 'Move to…', 'folder', () => showCommandDestinations(tab.id)),
          commandTask('result:pin-to', 'Pin to…', 'pin', () => showCommandDestinations(tab.id, true)),
        );
        if (tab.pinned) {
          actions.push(
            commandTask('result:reset', 'Reset pinned tab', 'undo', () =>
              closeAndRunCommand(() => invoke('tab:reset-pin', { id: tab.id })),
            ),
          );
          if (tab.pinnedUrl !== tab.url)
            actions.push(
              commandTask('result:replace', 'Replace pin with current page', 'pin', () =>
                closeAndRunCommand(() => invoke('tab:replace-pin', { id: tab.id })),
              ),
            );
        }
        if (!tab.closed)
          actions.push(
            commandTask('result:close', tab.pinned ? 'Close page · keep pin' : 'Close tab', 'close', () =>
              closeAndRunCommand(() => invoke('tab:close', { id: tab.id })),
            ),
          );
      }
      return actions;
    },
    `Actions for ${item.label}`,
  );
  return true;
}
function enterSiteSearch(engine) {
  pushCommandStep();
  ui.commandSiteSearch = engine;
  refreshCommandStep();
}
function siteSearches() {
  return globalThis.ZacroSiteSearch.normalizeSiteSearches(state.settings.siteSearches);
}
function showSiteSearches() {
  enterCommandContext('Site Search', () => [
    commandTask('search:add', 'Add site search', 'plus', () => showSiteSearchForm()),
    ...siteSearches().map((engine) => ({
      ...commandTask(
        `search:edit:${engine.id}`,
        engine.name,
        'search',
        () => showSiteSearchForm(engine.id),
        hostname(engine.url),
      ),
      type: engine.keyword,
    })),
  ]);
}
function showSiteSearchForm(id) {
  const engine = siteSearches().find((item) => item.id === id);
  if (!engine && siteSearches().length >= 20) return toast('You can save up to 20 site searches.');
  formDialog(
    engine ? 'Edit site search' : 'Add site search',
    'Type its keyword, press Tab, then enter your search.',
    `<label class="field">Name<input name="name" value="${esc(engine?.name || '')}" maxlength="40" required></label><label class="field">Keyword<input name="keyword" value="${esc(engine?.keyword || '')}" maxlength="24" placeholder="e.g. docs" required autocapitalize="none" spellcheck="false"></label><label class="field">Search URL<input name="url" value="${esc(engine?.url || '')}" maxlength="2048" placeholder="https://example.com/search?q=%s" required spellcheck="false"></label><p class="provider-note">Use %s in place of the search query.</p>${engine ? `<button type="button" class="secondary" data-action="ui:site-search-delete" data-id="${esc(engine.id)}">Remove search</button>` : ''}`,
    'Save',
    async (data, context) => {
      if (!context.isCurrent()) return;
      const next = {
        id: engine?.id || crypto.randomUUID(),
        name: String(data.get('name') || ''),
        keyword: String(data.get('keyword') || ''),
        url: String(data.get('url') || ''),
      };
      const error = globalThis.ZacroSiteSearch.siteSearchError(next);
      if (error) throw new Error(error);
      if (
        siteSearches().some(
          (item) => item.id !== next.id && item.keyword === next.keyword.trim().toLowerCase(),
        )
      )
        throw new Error('That keyword is already assigned to another site search.');
      await invoke('settings:update', {
        values: { siteSearches: [...siteSearches().filter((item) => item.id !== next.id), next] },
      });
      applyState(await invoke('state:get'));
      if (context.close()) {
        openCommand('newtab');
        showSiteSearches();
      }
    },
  );
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
  if (ui.commandSiteSearch) {
    const engine = siteSearches().find((item) => item.id === ui.commandSiteSearch.id);
    if (!engine || !raw || raw.length > 8000) return [];
    const url = globalThis.ZacroSiteSearch.siteSearchURL(engine, raw);
    return [
      {
        id: 'site-search',
        kind: 'navigation',
        label: raw,
        symbol: 'search',
        type: `Search ${engine.name}`,
        url,
        run: () => commitNavigation(url),
      },
    ];
  }
  if (ui.commandContext) {
    return ui.commandContext
      .options()
      .map((item, index) => ({
        ...item,
        score: raw ? Math.max(fuzzyScore(raw, item.label), fuzzyScore(raw, item.description) * 0.8) : -index,
      }))
      .filter((item) => !raw || item.score >= 20)
      .sort((a, b) => b.score - a.score);
  }
  const prefix = { '>': 'action', '/': 'action', '@': 'tab', '#': 'space' }[raw[0]];
  const filter = prefix || ui.commandFilter || 'all';
  const actionsOnly = filter === 'action';
  const q = (prefix ? raw.slice(1) : raw).trim();
  const options = [];
  const add = (item) => {
    if (filter !== 'all' && item.kind !== filter) return;
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
      if (!q && filter === 'all' && (tab.id === state.activeTabId || index > 5)) continue;
      add({
        id: `tab:${tab.id}`,
        kind: 'tab',
        label: tabLabel(tab),
        description:
          tab.spaceId === state.activeSpaceId
            ? hostname(tab.url)
            : state.spaces.find((space) => space.id === tab.spaceId)?.name,
        keywords: `${tab.url} ${tab.title || ''} ${tab.pinnedUrl || ''}`,
        url: tab.url,
        symbol: 'globe',
        type:
          tab.pinned && !state.runtime?.pages?.[tab.id]?.loaded
            ? tab.favorite
              ? 'Open favorite'
              : 'Open pinned tab'
            : 'Switch to tab',
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
        if (!q && filter === 'all' && index > 2) continue;
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
        symbol: space.icon || 'circle',
        type: 'Space',
        priority: q ? 9 : 30,
        run: () => {
          closeDialog({ restore: false });
          return invoke('space:activate', { id: space.id });
        },
      });
    for (const folder of state.folders) {
      const space = state.spaces.find(
        (item) => item.id === folder.spaceId && item.profileId === activeProfile()?.id,
      );
      if (!space) continue;
      add({
        id: `folder:${folder.id}`,
        kind: 'folder',
        label: folder.name,
        description: space.name,
        keywords: 'folder reveal find organize',
        symbol: 'folder',
        type: 'Folder',
        priority: q ? 10 : 15,
        run: async () => {
          closeDialog({ restore: false });
          await invoke('space:activate', { id: space.id });
          ui.closedFolders.delete(folder.id);
          applyState(await invoke('state:get'));
          await focusSidebar();
          requestAnimationFrame(() => {
            const heading = $(`[data-key="folder-${CSS.escape(folder.id)}"]`);
            heading?.focus();
            heading?.scrollIntoView({ block: 'nearest' });
          });
        },
      });
    }
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
  if (q && filter === 'all') {
    const site = siteSearches().find((item) => item.keyword === q.toLowerCase());
    if (site)
      options.push({
        id: `site:${site.id}`,
        kind: 'action',
        label: `Search ${site.name}`,
        description: hostname(site.url),
        symbol: 'search',
        type: 'Tab',
        score: 44,
        run: () => enterSiteSearch(site),
      });
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
  return options
    .sort((a, b) => b.score - a.score)
    .slice(0, actionsOnly ? 80 : q || filter !== 'all' ? 32 : 8);
}
function openCommand(mode = 'newtab', query, { automatic = false } = {}) {
  ui.commandTrail = [];
  ui.commandContext = null;
  ui.commandSiteSearch = null;
  ui.commandFilter = 'all';
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
    `<div class="command-input-wrap">${icon('search')}<input id="command-input" type="text" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="command-results" aria-label="Search tabs, history, Spaces and actions, or enter a URL" placeholder="Search or enter a URL" value="${esc(ui.commandQuery)}" autocomplete="off" spellcheck="false"><button type="button" class="command-mode" data-action="ui:command-mode" aria-label="Change navigation destination"></button></div><div id="command-results" class="command-results" role="listbox" aria-label="Suggestions"></div><footer class="command-footer"><span><kbd>↑↓</kbd> Select <kbd>↵</kbd> Open</span><span class="command-context-hint"></span></footer>`,
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
  let filters = $('.command-filters');
  if (!filters) {
    filters = document.createElement('div');
    filters.className = 'command-filters';
    filters.setAttribute('role', 'group');
    filters.setAttribute('aria-label', 'Search scope');
    filters.innerHTML = [
      ['all', 'All'],
      ['tab', 'Tabs'],
      ['space', 'Spaces'],
      ['folder', 'Folders'],
      ['bookmark', 'Bookmarks'],
      ['history', 'History'],
      ['action', 'Actions'],
    ]
      .map(
        ([id, name]) =>
          `<button type="button" data-action="ui:command-filter" data-filter="${id}">${name}</button>`,
      )
      .join('');
    root.before(filters);
  }
  filters.hidden = Boolean(ui.commandContext || ui.commandSiteSearch);
  const prefixFilter = { '>': 'action', '/': 'action', '@': 'tab', '#': 'space' }[ui.commandQuery.trim()[0]];
  for (const item of $$('button', filters))
    item.setAttribute('aria-pressed', item.dataset.filter === (prefixFilter || ui.commandFilter));
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
      .join('') ||
    `<div class="command-empty" role="presentation">${ui.commandSiteSearch ? (ui.commandQuery.trim().length > 8000 ? 'Use a search of up to 8,000 characters' : `Type to search ${esc(ui.commandSiteSearch.name)}`) : 'No matches in this scope'}</div>`;
  const input = $('#command-input');
  input.placeholder = ui.commandSiteSearch
    ? `Search ${ui.commandSiteSearch.name}`
    : ui.commandContext
      ? ui.commandContext.title
      : 'Search or enter a URL';
  const inputLabel = ui.commandSiteSearch
    ? `Search ${ui.commandSiteSearch.name}`
    : ui.commandContext?.ariaLabel || 'Search tabs, history, Spaces and actions, or enter a URL';
  input.setAttribute('aria-label', inputLabel);
  let status = $('#command-status');
  if (!status) {
    status = document.createElement('div');
    status.id = 'command-status';
    status.className = 'sr-only';
    status.setAttribute('role', 'status');
    status.setAttribute('aria-live', 'polite');
    status.setAttribute('aria-atomic', 'true');
    root.after(status);
  }
  const announcement = `${inputLabel}. ${ui.commandItems.length ? `${ui.commandItems.length} results` : $('.command-empty', root)?.textContent || 'No matches'}`;
  if (status.textContent !== announcement) status.textContent = announcement;
  if (ui.commandItems.length)
    input?.setAttribute('aria-activedescendant', `command-option-${ui.commandIndex}`);
  else input?.removeAttribute('aria-activedescendant');
  const mode = $('.command-mode');
  const nested = Boolean(ui.commandContext || ui.commandSiteSearch);
  mode.textContent = nested ? 'Back' : ui.commandMode === 'address' ? 'This tab' : 'New tab';
  mode.setAttribute(
    'aria-label',
    nested
      ? 'Back to previous command step'
      : `Destination: ${ui.commandMode === 'address' ? 'current tab' : 'new tab'}. Change destination`,
  );
  const selectedItem = ui.commandItems[ui.commandIndex];
  $('.command-context-hint').innerHTML = nested
    ? '<kbd>Esc</kbd> Back'
    : ui.commandFilter === 'all' &&
        siteSearches().some((engine) => engine.keyword === ui.commandQuery.trim().toLowerCase())
      ? '<kbd>Tab</kbd> Search site'
      : ['tab', 'bookmark', 'history'].includes(selectedItem?.kind)
        ? '<kbd>Tab</kbd> Actions <kbd>Alt ↵</kbd> New tab'
        : ['', '/', '>'].includes(ui.commandQuery.trim())
          ? '<kbd>Tab</kbd> Actions <kbd>/</kbd> Commands'
          : selectedItem?.kind === 'navigation'
            ? '<kbd>Alt ↵</kbd> New tab <kbd>/</kbd> Commands'
            : '<kbd>/</kbd> Commands';
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
  ui.aiRequestId = null;
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
  if (!question || ui.aiBusy || ui.aiSubmitting || ui.aiContextChanging) return false;
  if (activeProfile()?.private) {
    toast('AI is unavailable in private browsing.');
    return false;
  }
  if (!(ui.aiStatus?.configured ?? state.runtime?.aiConfigured)) {
    prepareDisconnectedQuestion(question);
    return false;
  }
  const serial = ++ui.aiSubmissionSerial;
  const context = {
    profileId: activeProfile()?.id,
    kind: ui.aiContext,
    pages: ui.aiGrantedPages.map((page) => ({ ...page })),
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
      JSON.stringify(context.pages) !== JSON.stringify(ui.aiGrantedPages) ||
      aiContextStale(context.pages)
    ) {
      toast('The browsing context changed. Review the selected pages before sending.');
      return false;
    }
    ui.aiStatus = status;
    if (status.busy) {
      toast('The previous request is still stopping. Try again in a moment.');
      return false;
    }
    if (!status?.configured || activeProfile()?.private) {
      if (activeProfile()?.private) toast('AI is unavailable in private browsing.');
      else prepareDisconnectedQuestion(question);
      return false;
    }
    if (context.kind === 'tabs' && !context.pages.length) {
      showTabSelection();
      return false;
    }
    if (context.kind === 'page' && !context.pages.length) {
      toast('Open a page first, or choose web research.');
      return false;
    }
    const composer = $('#ai-question');
    if (composer?.value.trim() === question) rememberAIDraft('');
    const request = {
      ...context,
      question,
      research: context.kind === 'research' && status.researchSupported !== false,
    };
    const requestId = crypto.randomUUID();
    ui.aiRequestId = requestId;
    ui.aiMessages.push({ role: 'user', text: question, request });
    ui.aiBusy = true;
    ui.aiSubmitting = false;
    ui.aiSources = [];
    ui.aiProgress = 'Looking into it…';
    ui.aiProfileId = context.profileId;
    renderAIUpdate(true);
    const args = { question, requestId };
    if (context.kind !== 'research') {
      args.tabIds = context.pages.map((page) => page.id);
      args.contextTabs = context.pages.map(({ id, url }) => ({ id, url }));
    }
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
  // Provider responses can arrive after a reset or profile/context change.
  // Production turn events carry an identifier; never attach an old turn to a
  // newly prepared conversation. Untagged events remain usable for status and
  // older host fixtures, which do not expose user content from another turn.
  if (
    ['ai:progress', 'ai:delta', 'ai:answer', 'ai:error', 'ai:cancelled'].includes(event.type) &&
    event.requestId &&
    event.requestId !== ui.aiRequestId
  )
    return;
  switch (event.type) {
    case 'newtab:show':
      closeDialog({ restore: false });
      safely(invoke('state:get').then(applyState));
      break;
    case 'shortcut': {
      const action = {
        shortcuts: 'ui:shortcuts',
        'browser-menu': 'ui:menu',
        'focus-sidebar': 'ui:focus-sidebar',
        'reveal-tab': 'ui:focus-sidebar',
        onboarding: 'ui:onboarding',
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
    case 'peek:motion':
      paintPeekMotion(event);
      break;
    case 'page:focused':
      closeLibraryChooser();
      break;
    case 'focus:chrome':
      if (ui.dialog) ($('#command-input') || $('#dialog-root button:not(:disabled)'))?.focus();
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
      if (
        ui.dialog === 'command' &&
        !event.query &&
        ui.commandMode === (event.mode === 'newtab' ? 'newtab' : 'address')
      )
        dismissDialog();
      else openCommand(event.mode || 'navigate', event.query);
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
        ui.aiMessages.at(-1).incomplete = true;
      }
      if (event.code === 'CANCELLED') {
        if (!ui.aiMessages.at(-1)?.incomplete)
          ui.aiMessages.push({
            role: 'assistant',
            text: 'Response stopped before an answer was completed.',
            incomplete: true,
          });
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
        ui.aiMessages.at(-1).incomplete = true;
      } else if (!ui.aiMessages.at(-1)?.incomplete)
        ui.aiMessages.push({
          role: 'assistant',
          text: 'Response stopped before an answer was completed.',
          incomplete: true,
        });
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
      if (backCommandStep()) return;
      ui.commandMode = ui.commandMode === 'address' ? 'newtab' : 'address';
      renderCommands({ preserve: true });
      $('#command-input')?.focus();
      return;
    case 'ui:command-filter':
      if (!['all', 'tab', 'space', 'folder', 'bookmark', 'history', 'action'].includes(data.filter)) return;
      ui.commandFilter = data.filter;
      ui.commandQuery = ui.commandQuery.replace(/^[\s]*[/>@#]\s*/, '');
      $('#command-input').value = ui.commandQuery;
      ui.commandIndex = 0;
      renderCommands();
      $('#command-input').focus();
      return;
    case 'ui:site-search-delete': {
      await invoke('settings:update', {
        values: { siteSearches: siteSearches().filter((engine) => engine.id !== id) },
      });
      applyState(await invoke('state:get'));
      openCommand('newtab');
      showSiteSearches();
      return;
    }
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
    case 'ui:focus-sidebar':
      return focusSidebar();
    case 'ui:onboarding':
      showOnboarding();
      return;
    case 'ui:onboarding-next':
      showOnboarding(ui.onboardingStep + 1);
      return;
    case 'ui:onboarding-back':
      showOnboarding(ui.onboardingStep - 1);
      return;
    case 'ui:onboarding-step':
      showOnboarding(data.id);
      return;
    case 'ui:onboarding-finish':
      return finishOnboarding();
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
    case 'ui:rename-space': {
      const space = state.spaces.find((item) => item.id === id && item.profileId === activeProfile()?.id);
      if (!space) return;
      formDialog(
        'Rename Space',
        '',
        field('name', 'Space name', space.name, 'text', 'required maxlength="60"'),
        'Save',
        async (values, context) => {
          if (!context.isCurrent()) return;
          await invoke('space:update', { id, name: values.get('name') });
          if (context.isCurrent()) context.close();
        },
      );
      return;
    }
    case 'ui:space-move-tab': {
      const space = state.spaces.find((item) => item.id === id && item.profileId === activeProfile()?.id);
      const tab = state.tabs.find((item) => item.id === data.sourceTab);
      if (!space || !tab || tab.profileId !== space.profileId || tab.spaceId === id) return;
      closeDialog();
      return invoke('tab:move', { id: tab.id, spaceId: id, folderId: null });
    }
    case 'ui:color':
      ui.selectedColor = data.color;
      $$('.color-option').forEach((b) => {
        b.classList.toggle('selected', b.dataset.color === data.color);
        b.setAttribute('aria-pressed', b.dataset.color === data.color);
      });
      if ($('#modal-form')?.elements['theme-color'])
        $('#modal-form').elements['theme-color'].value = data.color;
      updateSpacePreview();
      return;
    case 'ui:space-icon':
      if (!spaceIcons.includes(data.icon) || !$('#modal-form')?.elements['space-icon']) return;
      $('#modal-form').elements['space-icon'].value = data.icon;
      for (const item of $$('.space-icon-options button'))
        item.setAttribute('aria-pressed', item.dataset.icon === data.icon);
      updateSpacePreview();
      return;
    case 'ui:delete-space': {
      const s = state.spaces.find((s) => s.id === id);
      if (!s || state.spaces.filter((item) => item.profileId === s.profileId).length < 2) return;
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
        if (!activeTab().favorite) await invoke('tab:favorite', { id: state.activeTabId });
        else toast('This page is already a favorite.');
      } else toast('Open a page, then add it to Favorites.');
      return;
    case 'ui:tab-pin':
      closeDialog();
      return invoke('tab:pin', { id });
    case 'ui:tab-favorite': {
      const tab = state.tabs.find((item) => item.id === id);
      closeDialog();
      return invoke('tab:favorite', { id, favorite: !tab?.favorite });
    }
    case 'ui:tab-reset-pin':
      closeDialog();
      return invoke('tab:reset-pin', { id });
    case 'ui:tab-replace-pin':
      closeDialog();
      return invoke('tab:replace-pin', { id });
    case 'ui:tab-close':
      closeDialog();
      return invoke('tab:close', { id });
    case 'ui:tab-sleep': {
      closeDialog();
      const result = await invoke('tab:sleep', { id });
      if (!result?.slept) toast('This page is in use or has unsaved work.');
      return;
    }
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
      const documentURL = (value) => {
        try {
          const url = new URL(value);
          url.hash = '';
          return url.href;
        } catch {
          return '';
        }
      };
      const tab = state.tabs.find(
        (t) =>
          t.id === id && t.profileId === activeProfile()?.id && documentURL(t.url) === documentURL(data.url),
      );
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
    case 'ui:ai-review-saved': {
      if (ui.aiBusy || ui.aiSubmitting || ui.aiContextChanging) return;
      const index = Number(data.index);
      const question = ui.aiSavedQuestions[index];
      if (typeof question !== 'string') return;
      rememberAIDraft();
      const previous = ui.aiDraft;
      ui.aiSavedQuestions.splice(index, 1);
      if (previous.trim() && previous.trim() !== question && !ui.aiSavedQuestions.includes(previous))
        ui.aiSavedQuestions.push(previous);
      rememberAIDraft(question);
      renderAIUpdate(false);
      $('#ai-question')?.focus();
      return;
    }
    case 'ui:ai-discard-saved':
      if (Number(data.index) === 0) ui.aiSavedQuestions.splice(0, 1);
      renderAIUpdate(false);
      return;
    case 'ui:ai-prompt':
      openPanel('ai');
      if (!ui.aiDraft.trim()) rememberAIDraft(data.prompt || '');
      $('#ai-question')?.focus();
      return;
    case 'ui:ai-intent':
      return openAIIntent(data.intent);
    case 'ui:ai-page': {
      const page = aiPageGrant(activeTab());
      if (!page) {
        toast('Open a web page or text PDF first.');
        return;
      }
      if (!(await setAIContext('page', [page]))) return;
      openPanel('ai');
      return;
    }
    case 'ui:ai-select-tabs':
      showTabSelection();
      return;
    case 'ui:ai-reset':
      await setAIContext('research', [], { force: true });
      $('#ai-question')?.focus();
      return;
    case 'ui:ai-clear-context':
      await setAIContext('research');
      return;
    case 'ui:ai-remove-context': {
      const pages = ui.aiGrantedPages.filter((page) => page.id !== id);
      await setAIContext(pages.length ? ui.aiContext : 'research', pages);
      return;
    }
    case 'ui:ai-refresh-context': {
      if (ui.aiContext === 'tabs') {
        showTabSelection();
        return;
      }
      const page = aiPageGrant(state.tabs.find((tab) => tab.id === ui.aiGrantedPages[0]?.id));
      if (!page) {
        toast('The selected page closed. Choose another page to share.');
        return;
      }
      await setAIContext('page', [page]);
      return;
    }
    case 'ui:ai-copy': {
      const message = ui.aiMessages[Number(data.index)];
      if (!message || message.role !== 'assistant' || message.error || message.streaming) return;
      const sources = message.sources
        ?.map((source, index) => `${index + 1}. ${source.title || hostname(source.url)} — ${source.url}`)
        .join('\n');
      await invoke('clipboard:write-text', {
        text: [message.text, message.warning, sources ? 'Sources\n' + sources : '']
          .filter(Boolean)
          .join('\n\n'),
      });
      toast('Answer copied with its sources.');
      return;
    }
    case 'ui:ai-edit':
    case 'ui:ai-retry': {
      const request = ui.aiMessages[Number(data.index)]?.request;
      if (!request || request.profileId !== activeProfile()?.id || ui.aiBusy || ui.aiSubmitting) return;
      if (aiContextStale(request.pages)) {
        toast('Those pages changed or closed. Review the context before asking again.');
        return;
      }
      rememberAIDraft();
      if (action === 'ui:ai-edit' && ui.aiDraft.trim() && ui.aiDraft.trim() !== request.question) {
        toast('Your unfinished question was kept. Clear it before editing an earlier question.');
        return;
      }
      if (!(await setAIContext(request.kind, request.pages, { force: action === 'ui:ai-edit' }))) return;
      if (action === 'ui:ai-retry') return askAI(request.question);
      rememberAIDraft(request.question);
      $('#ai-question')?.focus();
      return;
    }
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
    case 'ui:ai-login-cancel': {
      const profile = activeProfile()?.id,
        serial = ui.aiProviderSerial;
      const status = await invoke('ai:login-cancel');
      if (profile !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
      ui.aiStatus = status;
      ui.aiSigningIn = false;
      renderPanel(true);
      return;
    }
    case 'ui:ai-disconnect': {
      const profile = activeProfile()?.id,
        serial = ui.aiProviderSerial;
      invalidateAIRequest();
      await invoke('ai:disconnect');
      if (profile !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
      const status = await invoke('ai:status');
      if (profile !== activeProfile()?.id || serial !== ui.aiProviderSerial) return;
      ui.aiStatus = status;
      ui.aiMessages = [];
      ui.aiSources = [];
      ui.aiBusy = false;
      if (state.runtime) state.runtime.aiConfigured = false;
      ui.panelSignature = '';
      renderPanel(true);
      toast('Disconnected AI provider.');
      return;
    }
    case 'ai:cancel': {
      invalidateAIRequest();
      const profile = activeProfile()?.id,
        serial = ui.aiSubmissionSerial;
      await invoke('ai:cancel');
      if (profile !== activeProfile()?.id || serial !== ui.aiSubmissionSerial) return;
      if (ui.aiMessages.at(-1)?.streaming) {
        ui.aiMessages.at(-1).streaming = false;
        ui.aiMessages.at(-1).incomplete = true;
        ui.aiMessages.at(-1).warning = 'Response stopped. This answer is incomplete.';
      } else if (ui.aiMessages.at(-1)?.role === 'user')
        ui.aiMessages.push({
          role: 'assistant',
          text: 'Response stopped before an answer was completed.',
          incomplete: true,
        });
      ui.aiBusy = false;
      ui.aiProgress = '';
      renderPanel(true);
      return;
    }
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
  if (target.id === 'ai-question') {
    rememberAIDraft(target.value);
  } else if (target.id === 'command-input') {
    ui.commandQuery = target.value;
    ui.commandIndex = 0;
    renderCommands();
  } else if (target.id === 'shortcut-search') {
    ui.shortcutQuery = target.value;
    renderShortcutRows();
  } else if (target.id === 'ai-base-url') {
    syncAPIKeyRequirement();
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
  if (target.dataset.profileArchive) {
    const value = target.value === 'inherit' ? null : Number(target.value);
    safely(
      invoke('profile:update', {
        id: target.dataset.profileArchive,
        values: { archiveAfterHours: value },
      }).then(async () => {
        applyState(await invoke('state:get'));
        if (ui.dialog === 'profiles') {
          for (const select of $$('[data-profile-archive]')) {
            const option = select.querySelector('option[value="inherit"]');
            const hours = state.settings.archiveAfterHours;
            if (option) option.textContent = `Use default · ${hours ? `${hours} hours` : 'Never'}`;
          }
        }
      }),
    );
  } else if (target.dataset.setting) {
    let value = target.type === 'checkbox' ? target.checked : target.value;
    if (
      [
        'archiveAfterHours',
        'openSourcesLimit',
        'sidebarWidth',
        'pinnedSleepMinutes',
        'pageGutter',
        'pageRadius',
        'motionScale',
      ].includes(target.dataset.setting)
    )
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
      renderPanel(true);
    } else {
      const page = aiPageGrant(activeTab());
      if (next === 'page' && !page) {
        toast('Open a web page or text PDF first.');
        renderPanel(true);
        return;
      }
      safely(setAIContext(next, page ? [page] : []));
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
      refreshShortcutEditor();
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
  if (handleSidebarKeyboard(event)) return;
  const cmd = primaryModifier(event);
  if (ui.dialog === 'command' && event.target.id === 'command-input') {
    if (
      (event.key === 'Escape' ||
        (event.key === 'Tab' && event.shiftKey) ||
        (event.key === 'Backspace' && !ui.commandQuery)) &&
      ui.commandTrail.length
    ) {
      event.preventDefault();
      backCommandStep();
      return;
    }
    if (event.key === 'Tab' && !event.shiftKey && !ui.commandContext && !ui.commandSiteSearch) {
      const engine =
        ui.commandFilter === 'all'
          ? siteSearches().find((item) => item.keyword === ui.commandQuery.trim().toLowerCase())
          : null;
      if (engine) {
        event.preventDefault();
        enterSiteSearch(engine);
        return;
      }
      if (showCommandResultActions(ui.commandItems[ui.commandIndex])) {
        event.preventDefault();
        return;
      }
    }
    if (
      event.key === 'Tab' &&
      !event.shiftKey &&
      !ui.commandContext &&
      !ui.commandSiteSearch &&
      ['', '/', '>'].includes(ui.commandQuery.trim())
    ) {
      event.preventDefault();
      ui.commandQuery = ui.commandQuery.trim() ? '' : '/';
      $('#command-input').value = ui.commandQuery;
      ui.commandIndex = 0;
      renderCommands();
      return;
    }
    if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp'].includes(event.key)) {
      event.preventDefault();
      const step = event.key.startsWith('Page') ? 6 : 1;
      const direction = ['ArrowDown', 'PageDown'].includes(event.key) ? 1 : -1;
      ui.commandIndex = event.key.startsWith('Page')
        ? Math.max(0, Math.min(ui.commandItems.length - 1, ui.commandIndex + direction * step))
        : (ui.commandIndex + direction + ui.commandItems.length) % Math.max(1, ui.commandItems.length);
      renderCommands();
      $(`#command-option-${ui.commandIndex}`)?.scrollIntoView({ block: 'nearest' });
      return;
    }
    if (event.key === 'Enter') {
      // Configurable shortcuts are dispatched by the native shortcut catalog.
      // An unassigned modifier+Enter must not retain an obsolete AI binding.
      if (event.ctrlKey || event.metaKey || event.shiftKey) return;
      event.preventDefault();
      selectCommand(ui.commandIndex, { separate: event.altKey });
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
      'button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),summary,[tabindex="0"]',
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
document.addEventListener('focusin', (event) => {
  if (!sidebarKeyboardItems().includes(event.target)) return;
  ui.sidebarFocusKey = event.target.dataset.key;
  prepareSidebarKeyboard();
});
document.addEventListener('contextmenu', (event) => {
  const space = event.target.closest('.space-dot');
  const tab = event.target.closest('[data-tab-id]');
  const folder = event.target.closest('[data-folder-id]');
  if (space) {
    event.preventDefault();
    showSpaceMenu(space.dataset.id);
  } else if (tab) {
    event.preventDefault();
    showTabMenu(tab.dataset.tabId);
  } else if (folder) {
    event.preventDefault();
    showFolderMenu(folder.dataset.folderId);
  } else event.preventDefault();
});
document.addEventListener('keydown', (event) => {
  if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')) return;
  const space = event.target.closest('.space-dot');
  if (!space) return;
  event.preventDefault();
  showSpaceMenu(space.dataset.id);
});
function clearDragFeedback() {
  $$('.drag-over,.drop-before,.drop-after').forEach((element) =>
    element.classList.remove('drag-over', 'drop-before', 'drop-after'),
  );
}
function dragDestination(event) {
  const drop = event.target.closest(
    '[data-drop-tab],[data-drop-favorites],[data-drop-pinned],[data-drop-folder]',
  );
  const source = state?.tabs.find((tab) => tab.id === ui.dragTab);
  if (!drop || !source || source.profileId !== activeProfile()?.id) return null;
  const target = drop.dataset.dropTab ? state.tabs.find((tab) => tab.id === drop.dataset.dropTab) : null;
  if (target?.id === source.id) return null;
  const favorite = Boolean(drop.closest('[data-drop-favorites]'));
  const pinned = favorite || Boolean(drop.closest('[data-drop-pinned]'));
  const folderId = favorite ? null : target ? target.folderId : drop.dataset.dropFolder || null;
  const rectangle = drop.getBoundingClientRect();
  const after =
    target &&
    (favorite
      ? event.clientX > rectangle.left + rectangle.width / 2
      : event.clientY > rectangle.top + rectangle.height / 2);
  const remaining = state.tabs.filter((tab) => tab.id !== source.id);
  let index;
  if (target) index = remaining.findIndex((tab) => tab.id === target.id) + (after ? 1 : 0);
  else {
    const siblings = remaining.filter((tab) =>
      favorite
        ? tab.favorite && tab.profileId === activeProfile()?.id
        : tab.spaceId === state.activeSpaceId &&
          !tab.favorite &&
          tab.pinned === pinned &&
          (tab.folderId || null) === folderId,
    );
    index = siblings.length ? remaining.indexOf(siblings.at(-1)) + 1 : remaining.length;
  }
  return {
    drop,
    after,
    payload: { id: source.id, spaceId: state.activeSpaceId, favorite, pinned, folderId, index },
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
  const drop = event.target.closest(
    '[data-drop-tab],[data-drop-favorites],[data-drop-pinned],[data-drop-folder]',
  );
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
  cancelRailResize();
  interruptSpaceScroll();
  stopShortcutRecording();
  refreshShortcutEditor();
});
window.addEventListener('resize', () => {
  cancelRailResize();
  interruptSpaceScroll();
  finishChromeMotion();
  if (state) {
    renderToolbar();
    renderWorkspace();
  }
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
