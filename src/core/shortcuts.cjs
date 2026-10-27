'use strict';

// One catalog drives native input, menus, command search, and the shortcut editor.
const entries = [
  ['command-palette', 'Command palette', 'Navigation', 'Mod+T', ['Mod+K']],
  ['open-location', 'Edit current address', 'Navigation', 'Mod+L'],
  ['sidebar-toggle', 'Toggle sidebar', 'Navigation', 'Mod+S'],
  ['focus-sidebar', 'Focus sidebar', 'Navigation', 'Mod+Alt+S'],
  ['reveal-tab', 'Reveal tab in sidebar', 'Navigation', ''],
  ['history-back', 'Back', 'Navigation', { darwin: 'Mod+[', other: 'Alt+Left' }],
  ['history-forward', 'Forward', 'Navigation', { darwin: 'Mod+]', other: 'Alt+Right' }],
  ['focus-chrome', 'Focus page / browser controls', 'Navigation', 'F6'],
  ['copy-url', 'Copy page address', 'Navigation', 'Mod+Shift+C'],
  ['next-space', 'Next Space', 'Spaces', 'Mod+Alt+Right'],
  ['previous-space', 'Previous Space', 'Spaces', 'Mod+Alt+Left'],
  ['new-space', 'Create Space', 'Spaces', 'Mod+Shift+E'],
  ['new-folder', 'Create folder', 'Spaces', 'Mod+Shift+O'],
  ['new-private-space', 'New private session', 'Spaces', 'Mod+Shift+N'],
  ['close-tab', 'Close tab or preview', 'Tabs', 'Mod+W'],
  ['reopen-tab', 'Restore closed tab', 'Tabs', 'Mod+Shift+T'],
  ['recent-tab', 'Next recent tab', 'Tabs', 'Ctrl+Tab'],
  ['previous-recent-tab', 'Previous recent tab', 'Tabs', 'Ctrl+Shift+Tab'],
  [
    'next-tab',
    'Next tab in sidebar',
    'Tabs',
    'Mod+Alt+Down',
    { darwin: ['Mod+Shift+]'], other: ['Ctrl+PageDown'] },
  ],
  [
    'previous-tab',
    'Previous tab in sidebar',
    'Tabs',
    'Mod+Alt+Up',
    { darwin: ['Mod+Shift+['], other: ['Ctrl+PageUp'] },
  ],
  ['pin-tab', 'Pin / unpin tab', 'Tabs', 'Mod+D'],
  ['duplicate-tab', 'Duplicate tab', 'Tabs', 'Mod+Shift+D'],
  ['rename-tab', 'Rename tab', 'Tabs', 'Mod+Alt+R'],
  ['move-tab', 'Move tab', 'Tabs', 'Mod+Alt+M'],
  ['mute-tab', 'Mute / unmute tab', 'Tabs', 'Mod+Shift+M'],
  ['split', 'Split view', 'Tabs', { darwin: 'Ctrl+Shift+=', other: 'Alt+Shift+=' }],
  ['peek-close', 'Close preview', 'Tabs', { darwin: 'Mod+Shift+Escape', other: 'Mod+Shift+.' }],
  ['peek-promote', 'Open preview as tab', 'Tabs', 'Mod+Shift+Enter'],
  ['reload', 'Reload page', 'Page', 'Mod+R', { darwin: [], other: ['F5'] }],
  [
    'force-reload',
    'Reload without cache',
    'Page',
    'Mod+Shift+R',
    { darwin: [], other: ['Ctrl+F5', 'Shift+F5'] },
  ],
  ['stop', 'Stop loading', 'Page', 'Mod+.'],
  ['find', 'Find on page', 'Page', 'Mod+F'],
  ['find-next', 'Find next', 'Page', 'Mod+G'],
  ['find-previous', 'Find previous', 'Page', 'Mod+Shift+G'],
  ['bookmark', 'Bookmark page', 'Page', 'Mod+Alt+D'],
  ['save-page', 'Save page as…', 'Page', 'Mod+Shift+S'],
  ['print', 'Print page', 'Page', 'Mod+P'],
  ['zoom-in', 'Zoom in', 'Page', 'Mod+=', ['Mod+Shift+=']],
  ['zoom-out', 'Zoom out', 'Page', 'Mod+-'],
  ['zoom-reset', 'Actual size', 'Page', 'Mod+0'],
  ['history', 'History', 'Library', { darwin: 'Mod+Y', other: 'Mod+H' }],
  ['downloads', 'Downloads', 'Library', 'Mod+J'],
  ['bookmarks', 'Bookmarks', 'Library', 'Mod+Shift+B'],
  ['archive', 'Archived tabs', 'Library', 'Mod+Shift+A'],
  ['extensions', 'Extensions', 'Library', 'Mod+E'],
  ['ai', 'Ask AI / open sources', 'Library', 'Mod+Alt+G', ['Mod+Enter']],
  ['preferences', 'Settings', 'Browser', 'Mod+,'],
  ['shortcuts', 'Keyboard shortcuts', 'Browser', 'Mod+Alt+K'],
  ['browser-menu', 'Browser menu', 'Browser', { darwin: '', other: 'F10' }],
  ['onboarding', 'Welcome tour', 'Browser', ''],
  ['open-browser', 'Open browser window', 'Browser', 'Mod+N'],
  ['close-window', 'Close window', 'Browser', 'Mod+Shift+W'],
  ['fullscreen', 'Toggle full screen', 'Browser', { darwin: 'Ctrl+Mod+F', other: 'F11' }],
  [
    'developer-tools',
    'Developer tools',
    'Browser',
    { darwin: 'Mod+Alt+I', other: 'Mod+Shift+I' },
    { darwin: [], other: ['F12'] },
  ],
  ...Array.from({ length: 9 }, (_, i) => [
    `tab-${i + 1}`,
    i === 8 ? 'Last tab' : `Tab ${i + 1}`,
    'Tab positions',
    `Mod+${i + 1}`,
  ]),
  ...Array.from({ length: 9 }, (_, i) => [
    `space-${i + 1}`,
    `Space ${i + 1}`,
    'Space positions',
    { darwin: `Ctrl+${i + 1}`, other: `Alt+${i + 1}` },
  ]),
];
const platformValue = (value, platform) =>
  value && !Array.isArray(value) && typeof value === 'object' ? (value[platform] ?? value.other) : value;
const modifiers = ['Ctrl', 'Mod', 'Alt', 'Shift'];
const keyNames = new Set([
  'Left',
  'Right',
  'Up',
  'Down',
  'Tab',
  'Enter',
  'Escape',
  'Space',
  'Backspace',
  'Delete',
  'Home',
  'End',
  'PageUp',
  'PageDown',
  'Insert',
]);
function normalizeAccelerator(value) {
  if (typeof value !== 'string' || value.length > 80) throw new Error('Choose a valid keyboard shortcut.');
  if (!value.trim()) return '';
  const pieces = value.trim().split('+');
  let key = pieces.pop();
  if (key === 'Plus') key = '=';
  if (key === 'Minus') key = '-';
  if (key === 'Comma') key = ',';
  if (key.length === 1) key = key.toUpperCase();
  if (!(/^[A-Z0-9,.[\]\/;='`\\-]$/.test(key) || /^F(?:[1-9]|1\d|2[0-4])$/.test(key) || keyNames.has(key)))
    throw new Error('That key cannot be used as a browser shortcut.');
  if (pieces.some((part) => !modifiers.includes(part)) || new Set(pieces).size !== pieces.length)
    throw new Error('Use Mod, Ctrl, Alt and Shift with one key.');
  if (!pieces.some((part) => ['Mod', 'Ctrl', 'Alt'].includes(part)) && !/^F\d+$/.test(key))
    throw new Error('Include Command/Control, Control or Option/Alt so ordinary typing stays available.');
  return [...modifiers.filter((part) => pieces.includes(part)), key].join('+');
}
function signature(accelerator, platform) {
  if (!accelerator) return '';
  const parts = accelerator.split('+');
  const key = parts.pop();
  const flags = new Set(
    parts.map((part) => (part === 'Mod' ? (platform === 'darwin' ? 'Meta' : 'Ctrl') : part)),
  );
  return ['Ctrl', 'Meta', 'Alt', 'Shift']
    .filter((part) => flags.has(part))
    .concat(key)
    .join('+');
}
function shortcutCatalog(platform = process.platform, overrides = {}) {
  const selected = overrides?.[platform] || {};
  return entries.map(([id, label, category, defaults, alternatives = []]) => {
    const defaultAccelerator = normalizeAccelerator(platformValue(defaults, platform));
    const customized = Object.hasOwn(selected, id);
    return {
      id,
      label,
      category,
      defaultAccelerator,
      accelerator: customized ? selected[id] : defaultAccelerator,
      aliases: customized ? [] : platformValue(alternatives, platform).map(normalizeAccelerator),
      customized,
      editable: true,
    };
  });
}
function reserved(accelerator, platform) {
  const common = ['Mod+A', 'Mod+C', 'Mod+V', 'Mod+X', 'Mod+Z', 'Mod+Shift+Z', 'Mod+Shift+V'];
  const system =
    platform === 'darwin'
      ? [
          'Mod+H',
          'Mod+Alt+H',
          'Mod+Q',
          'Mod+Tab',
          'Mod+Shift+Tab',
          'Mod+M',
          'Mod+Alt+Shift+V',
          'Ctrl+Space',
          'Ctrl+F2',
          'Mod+Space',
          'Mod+Alt+Escape',
          'Mod+Shift+3',
          'Mod+Shift+4',
          'Mod+Shift+5',
          'Ctrl+H',
          'Alt+Backspace',
        ]
      : ['Alt+F4', 'Alt+Tab', 'Alt+Shift+Tab', 'Ctrl+Alt+Delete', 'Ctrl+Shift+Escape', 'Ctrl+Y'];
  return [...common, ...system].some(
    (item) => signature(normalizeAccelerator(item), platform) === signature(accelerator, platform),
  );
}
function updateShortcut(overrides, platform, id, value) {
  const catalog = shortcutCatalog(platform, overrides);
  const entry = catalog.find((item) => item.id === id);
  if (!entry) throw new Error('Unknown browser shortcut.');
  const accelerator = normalizeAccelerator(value);
  if (accelerator && reserved(accelerator, platform))
    throw new Error(
      'That shortcut belongs to the operating system or text editing. Choose another combination.',
    );
  // Resetting a binding also restores its default aliases; all must be free.
  const requested =
    accelerator === entry.defaultAccelerator
      ? shortcutCatalog(platform).find((item) => item.id === id)
      : { accelerator, aliases: [] };
  const assigned = [requested.accelerator, ...requested.aliases]
    .filter(Boolean)
    .map((key) => signature(key, platform));
  const conflict = catalog.find(
    (item) =>
      item.id !== id &&
      [item.accelerator, ...item.aliases].some((key) => key && assigned.includes(signature(key, platform))),
  );
  if (conflict) throw new Error(`Already used by ${conflict.label}. Change or disable that shortcut first.`);
  const result = { ...overrides, [platform]: { ...overrides?.[platform], [id]: accelerator } };
  if (accelerator === entry.defaultAccelerator) delete result[platform][id];
  return result;
}
function sanitizeOverrides(raw) {
  const result = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return result;
  for (const platform of ['darwin', 'win32', 'linux']) {
    const values = raw[platform];
    if (!values || typeof values !== 'object' || Array.isArray(values)) continue;
    // First remove all default bindings being overridden, allowing swaps to survive a restart.
    const next = {};
    for (const [id] of entries) if (Object.hasOwn(values, id)) next[id] = '';
    result[platform] = next;
    for (const [id] of entries) {
      if (!Object.hasOwn(values, id)) continue;
      try {
        result[platform] = updateShortcut(result, platform, id, values[id])[platform];
      } catch {
        delete result[platform][id];
      }
    }
    // Damaged imports cannot introduce collisions through a rejected override's fallback.
    const seen = new Set();
    for (const item of shortcutCatalog(platform, result)) {
      const keys = [item.accelerator, ...item.aliases].filter(Boolean).map((key) => signature(key, platform));
      if (keys.some((key) => seen.has(key))) result[platform][item.id] = '';
      else keys.forEach((key) => seen.add(key));
    }
  }
  return result;
}
function matchShortcut(input, platform, overrides) {
  if (input.type !== 'keyDown' || input.isComposing || input.altGraph) return null;
  const physical = {
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
  };
  const codeKey = /^Key[A-Z]$|^Digit\d$/.test(input.code || '')
    ? input.code.replace(/^(Key|Digit)/, '')
    : physical[input.code];
  // Windows/Linux AltGr may arrive as Control+Alt without a public AltGraph
  // boolean. Never consume a printable character produced by that combination.
  if (
    platform !== 'darwin' &&
    input.control &&
    input.alt &&
    !input.meta &&
    input.key?.length === 1 &&
    (!codeKey || input.key.toUpperCase() !== codeKey)
  )
    return null;
  let key = input.key;
  if (codeKey && (input.control || input.meta || input.alt)) key = codeKey;
  if (key === '+') key = '=';
  key =
    { ArrowLeft: 'Left', ArrowRight: 'Right', ArrowUp: 'Up', ArrowDown: 'Down', ' ': 'Space' }[key] || key;
  if (key?.length === 1) key = key.toUpperCase();
  const pressed = [
    input.control && 'Ctrl',
    input.meta && 'Meta',
    input.alt && 'Alt',
    input.shift && 'Shift',
    key,
  ]
    .filter(Boolean)
    .join('+');
  return (
    shortcutCatalog(platform, overrides).find((item) =>
      [item.accelerator, ...item.aliases].some((value) => value && signature(value, platform) === pressed),
    )?.id || null
  );
}
function sidebarTabs(state, spaceId = state.activeSpaceId) {
  const tabs = state.tabs.filter(
    (tab) =>
      tab.spaceId === spaceId && (tab.pinned || tab.folderId || tab.url !== 'zacro://newtab' || tab.homePage),
  );
  const pins = tabs.filter((tab) => tab.pinned);
  const folders = state.folders.filter((folder) => folder.spaceId === spaceId);
  return [
    ...pins,
    ...folders.flatMap((folder) => tabs.filter((tab) => !tab.pinned && tab.folderId === folder.id)),
    ...tabs.filter((tab) => !tab.pinned && !tab.folderId),
  ];
}
function menuAccelerator(value) {
  return value
    ? value
        .split('+')
        .map((part) => ({ Mod: 'CommandOrControl', Ctrl: 'Control', '=': 'Plus' })[part] || part)
        .join('+')
    : undefined;
}
module.exports = {
  shortcutCatalog,
  normalizeAccelerator,
  updateShortcut,
  sanitizeOverrides,
  matchShortcut,
  menuAccelerator,
  sidebarTabs,
};
