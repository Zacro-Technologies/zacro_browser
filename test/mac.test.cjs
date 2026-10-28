'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { windowChrome, macShortcut, macMenuTemplate } = require('../src/main/mac.cjs');

test('Mac chrome keeps native traffic lights while other platforms keep their existing frame', () => {
  assert.deepEqual(windowChrome('darwin'), {
    frame: true,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 12 },
  });
  assert.deepEqual(windowChrome('win32'), { frame: false });
  assert.deepEqual(windowChrome('linux'), { frame: false });
});

test('Mac shortcuts reserve OS combinations and distinguish window, tab and navigation commands', () => {
  const key = (key, modifiers = {}) => macShortcut({ type: 'keyDown', key, ...modifiers });
  assert.equal(key('w', { meta: true }), 'close-tab');
  assert.equal(key('t', { meta: true }), 'command-palette');
  assert.equal(key('s', { meta: true }), 'sidebar-toggle');
  assert.equal(key('s', { meta: true, shift: true }), 'save-page');
  assert.equal(key('w', { meta: true, shift: true }), 'close-window');
  assert.equal(key('n', { meta: true }), 'open-browser');
  assert.equal(key('n', { meta: true, shift: true }), 'new-private-space');
  assert.equal(key(',', { meta: true }), 'preferences');
  assert.equal(key('[', { meta: true }), 'history-back');
  assert.equal(key(']', { meta: true }), 'history-forward');
  assert.equal(key('Tab', { control: true }), 'recent-tab');
  assert.equal(key('Tab', { control: true, shift: true }), 'previous-recent-tab');
  assert.equal(key('ArrowLeft', { meta: true, alt: true }), 'previous-space');
  assert.equal(key('ArrowRight', { meta: true, alt: true }), 'next-space');
  assert.equal(key('ArrowUp', { meta: true, alt: true }), 'previous-tab');
  assert.equal(key('ArrowDown', { meta: true, alt: true }), 'next-tab');
  assert.equal(key('f', { meta: true, control: true }), 'fullscreen');
  assert.equal(key('y', { meta: true }), 'history');
  for (const reserved of ['h', 'q', 'Tab', 'z', 'x', 'c', 'v', 'a'])
    assert.equal(key(reserved, { meta: true }), null, `${reserved} remains native`);
  assert.equal(key('t', { meta: true, control: true }), null);
  assert.equal(key('t', { meta: true, alt: true }), null);
  assert.equal(key('t', { meta: true, isComposing: true }), null);
  assert.equal(macShortcut({ type: 'keyUp', key: 't', meta: true }), null);
});

test('Mac menu commands have unique accelerators and edit commands route to their focused-target callback', () => {
  const actions = [];
  const edits = [];
  const menu = macMenuTemplate(
    (action) => actions.push(action),
    (action) => edits.push(action),
  );
  const flatten = (items) => items.flatMap((item) => [item, ...flatten(item.submenu || [])]);
  const items = flatten(menu);
  const byId = (id) => items.find((item) => item.id === id);
  const accelerators = items.map((item) => item.accelerator).filter(Boolean);
  assert.equal(new Set(accelerators).size, accelerators.length);
  byId('command-palette').click();
  byId('preferences').click();
  byId('close-window').click();
  byId('edit-select-all').click();
  byId('edit-undo').click();
  assert.deepEqual(actions, ['command-palette', 'preferences', 'close-window']);
  assert.deepEqual(edits, ['selectAll', 'undo']);
  for (const role of ['services', 'hide', 'hideOthers', 'quit', 'minimize', 'zoom', 'front'])
    assert(items.some((item) => item.role === role));
  assert.equal(byId('close-tab').accelerator, 'Command+W');
  assert.equal(byId('close-window').accelerator, 'Command+Shift+W');
  assert.equal(byId('open-browser').label, 'Open Browser Window');
  assert(!items.some((item) => ['selectNextTab', 'mergeAllWindows', 'toggleTabBar'].includes(item.role)));
});
