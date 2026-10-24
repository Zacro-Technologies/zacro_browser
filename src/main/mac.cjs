'use strict';

// Kept independent of Electron so platform conventions can be verified on all
// development hosts. Native integration is exercised separately on macOS.
function windowChrome(platform) {
  return platform === 'darwin'
    ? { frame: true, titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 16, y: 16 } }
    : { frame: false };
}

function macShortcut(input) {
  if (input.type !== 'keyDown' || input.isComposing) return null;
  const key = input.key?.toLowerCase();
  if (input.control && !input.meta && !input.alt && key === 'tab')
    return input.shift ? 'previous-tab' : 'next-tab';
  if (!input.meta) return null;
  if (input.control) return !input.alt && !input.shift && key === 'f' ? 'fullscreen' : null;
  if (input.alt) {
    if (input.shift) return null;
    return { arrowleft: 'previous-tab', arrowright: 'next-tab', i: 'developer-tools' }[key] || null;
  }
  if (input.shift)
    return (
      {
        t: 'reopen-tab',
        n: 'new-private-space',
        w: 'close-window',
        r: 'force-reload',
        b: 'sidebar-toggle',
        j: 'downloads',
        '+': 'zoom-in',
        '=': 'zoom-in',
      }[key] || null
    );
  return (
    {
      n: 'open-browser',
      t: 'new-tab',
      w: 'close-tab',
      l: 'open-location',
      k: 'open-location',
      ',': 'preferences',
      f: 'find',
      p: 'print',
      r: 'reload',
      d: 'bookmark',
      y: 'history',
      j: 'downloads',
      '[': 'history-back',
      ']': 'history-forward',
      '+': 'zoom-in',
      '=': 'zoom-in',
      '-': 'zoom-out',
      0: 'zoom-reset',
    }[key] || null
  );
}

function macMenuTemplate(run, edit) {
  const action = (id, label, accelerator) => ({ id, label, accelerator, click: () => run(id) });
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
        action('new-tab', 'New Tab', 'Command+T'),
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
        action('bookmark', 'Bookmark This Page', 'Command+D'),
      ],
    },
    {
      role: 'windowMenu',
      submenu: [{ role: 'minimize' }, { role: 'zoom' }, separator, { role: 'front' }],
    },
    {
      role: 'help',
      submenu: [action('releases', 'Zacro Releases'), action('issues', 'Report an Issue')],
    },
  ];
}

module.exports = { windowChrome, macShortcut, macMenuTemplate };
