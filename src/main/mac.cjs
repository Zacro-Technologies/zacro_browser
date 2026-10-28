'use strict';
const { matchShortcut, shortcutCatalog, menuAccelerator } = require('../core/shortcuts.cjs');

// Kept independent of Electron so platform conventions can be verified on all
// development hosts. Native integration is exercised separately on macOS.
function windowChrome(platform) {
  return platform === 'darwin'
    ? { frame: true, titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 16, y: 12 } }
    : { frame: false };
}

function macShortcut(input, overrides = {}) {
  return matchShortcut(input, 'darwin', overrides);
}

function macMenuTemplate(run, edit, overrides = {}) {
  const catalog = shortcutCatalog('darwin', overrides);
  const action = (id, label) => ({
    id,
    label,
    accelerator: menuAccelerator(catalog.find((entry) => entry.id === id)?.accelerator)?.replace(
      'CommandOrControl',
      'Command',
    ),
    click: () => run(id),
  });
  const separator = { type: 'separator' };
  const editing = (id, label, accelerator) => ({
    id: `edit-${id === 'selectAll' ? 'select-all' : id === 'pasteAndMatchStyle' ? 'paste-match-style' : id}`,
    label,
    accelerator,
    click: () => edit(id),
  });
  return [
    {
      label: 'Zacro',
      submenu: [
        { role: 'about' },
        separator,
        action('preferences', 'Settings…', 'Command+,'),
        action('shortcuts', 'Keyboard Shortcuts…'),
        separator,
        { role: 'services' },
        separator,
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        separator,
        { role: 'quit' },
      ],
    },
    {
      label: 'File',
      submenu: [
        action('command-palette', 'Command Palette…'),
        action('new-tab', 'New Tab Page'),
        action('open-browser', 'Open Browser Window', 'Command+N'),
        action('new-private-space', 'New Private Space', 'Command+Shift+N'),
        action('open-location', 'Open Location…', 'Command+L'),
        action('reopen-tab', 'Reopen Closed Tab', 'Command+Shift+T'),
        separator,
        action('close-tab', 'Close Tab', 'Command+W'),
        action('close-window', 'Close Window', 'Command+Shift+W'),
        separator,
        action('import', 'Import Browser Data…'),
        action('export', 'Export Browser Data…'),
        separator,
        action('save-page', 'Save Page As…'),
        action('print', 'Print…', 'Command+P'),
      ],
    },
    {
      label: 'Edit',
      submenu: [
        editing('undo', 'Undo', 'Command+Z'),
        editing('redo', 'Redo', 'Command+Shift+Z'),
        separator,
        editing('cut', 'Cut', 'Command+X'),
        editing('copy', 'Copy', 'Command+C'),
        editing('paste', 'Paste', 'Command+V'),
        editing('pasteAndMatchStyle', 'Paste and Match Style', 'Command+Option+Shift+V'),
        editing('selectAll', 'Select All', 'Command+A'),
        separator,
        action('find', 'Find…', 'Command+F'),
        { label: 'Speech', submenu: [{ role: 'startSpeaking' }, { role: 'stopSpeaking' }] },
      ],
    },
    {
      label: 'View',
      submenu: [
        action('reload', 'Reload Page', 'Command+R'),
        action('force-reload', 'Reload Without Cache', 'Command+Shift+R'),
        separator,
        action('sidebar-toggle', 'Toggle Sidebar', 'Command+Shift+B'),
        action('focus-sidebar', 'Focus Sidebar'),
        action('reveal-tab', 'Reveal Tab in Sidebar'),
        action('zoom-in', 'Zoom In', 'Command+Plus'),
        action('zoom-out', 'Zoom Out', 'Command+-'),
        action('zoom-reset', 'Actual Size', 'Command+0'),
        separator,
        action('fullscreen', 'Enter Full Screen', 'Control+Command+F'),
        action('developer-tools', 'Developer Tools', 'Command+Option+I'),
      ],
    },
    {
      label: 'History',
      submenu: [
        action('history-back', 'Back', 'Command+['),
        action('history-forward', 'Forward', 'Command+]'),
        separator,
        action('history', 'Show History', 'Command+Y'),
        action('downloads', 'Downloads', 'Command+Shift+J'),
      ],
    },
    {
      label: 'Tabs',
      submenu: [
        action('previous-tab', 'Previous Tab', 'Control+Shift+Tab'),
        action('next-tab', 'Next Tab', 'Control+Tab'),
        separator,
        action('pin-tab', 'Pin / Unpin Tab'),
        action('duplicate-tab', 'Duplicate Tab'),
        action('rename-tab', 'Rename Tab…'),
        action('move-tab', 'Move Tab…'),
        action('mute-tab', 'Mute / Unmute Tab'),
        action('split', 'Split View…'),
        separator,
        action('previous-space', 'Previous Space'),
        action('next-space', 'Next Space'),
        action('new-space', 'New Space…'),
        action('new-folder', 'New Folder…'),
        separator,
        action('bookmark', 'Bookmark This Page', 'Command+D'),
      ],
    },
    {
      role: 'windowMenu',
      submenu: [{ role: 'minimize' }, { role: 'zoom' }, separator, { role: 'front' }],
    },
    {
      role: 'help',
      submenu: [
        action('onboarding', 'Welcome Tour'),
        separator,
        action('releases', 'Zacro Releases'),
        action('issues', 'Report an Issue'),
      ],
    },
  ];
}

module.exports = { windowChrome, macShortcut, macMenuTemplate };
