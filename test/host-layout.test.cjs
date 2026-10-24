'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  browserLayout,
  presentView,
  resolveSplit,
  restoreWindowPlacement,
} = require('../src/main/layout.cjs');

test('native pages align with shell toolbar, sidebar, and open panels without fractional seams', () => {
  const layout = browserLayout({ width: 1441, height: 941, sidebarWidth: 260, panelWidth: 400, split: true });
  assert.deepEqual(layout.primary, { x: 260, y: 44, width: 379, height: 889 });
  assert.deepEqual(layout.secondary, { x: 645, y: 44, width: 380, height: 889 });
  assert.equal(layout.secondary.x + layout.secondary.width + 400 + 16, 1441);
  assert.equal(layout.secondary.x - layout.primary.x - layout.primary.width, 6);
  assert.deepEqual(layout.peek, { x: 296, y: 96, width: 693, height: 801 });
});

test('hiding the sidebar reclaims its width while keeping the page, panel and split frame aligned', () => {
  const full = browserLayout({ width: 1000, height: 700, sidebarWidth: 0 });
  assert.deepEqual(full.primary, { x: 8, y: 44, width: 984, height: 648 });
  assert.equal(full.secondary, null);
  assert.deepEqual(full.peek, { x: 44, y: 96, width: 912, height: 560 });

  const split = browserLayout({
    width: 1000,
    height: 700,
    sidebarWidth: 0,
    panelWidth: 360,
    split: true,
  });
  assert.deepEqual(split.primary, { x: 8, y: 44, width: 305, height: 648 });
  assert.deepEqual(split.secondary, { x: 319, y: 44, width: 305, height: 648 });
  assert.equal(split.secondary.x + split.secondary.width + 360 + 16, 1000);
  assert.deepEqual(split.peek, { x: 44, y: 96, width: 544, height: 560 });

  const restored = browserLayout({ width: 1000, height: 700, sidebarWidth: 300 });
  assert.equal(restored.primary.x, 300, 'A custom sidebar width remains available after focus mode');
  assert.equal(browserLayout({ width: 1000, height: 700 }).primary.x, 230);
});

test('resizing and malformed dimensions keep native bounds finite and positive', () => {
  for (const width of [960, 1100, 1440, 3840, NaN]) {
    const layout = browserLayout({
      width,
      height: 640,
      sidebarWidth: Infinity,
      panelWidth: 10000,
      split: true,
    });
    for (const rectangle of Object.values(layout).filter(Boolean)) {
      for (const value of Object.values(rectangle)) assert(Number.isInteger(value));
      assert(rectangle.width > 0 && rectangle.height > 0);
    }
  }
});

test('unchanged native presentation does not toggle visibility or reset bounds', () => {
  const calls = [];
  const view = {
    setBounds: (value) => calls.push(['bounds', value]),
    setVisible: (value) => calls.push(['visible', value]),
  };
  const bounds = { x: 260, y: 60, width: 1000, height: 800 };
  let previous = presentView(view, { visible: false }, { visible: true, bounds });
  for (let i = 0; i < 20; i++)
    previous = presentView(view, previous, { visible: true, bounds: { ...bounds } });
  assert.equal(calls.length, 2);
  previous = presentView(view, previous, { visible: false });
  previous = presentView(view, previous, { visible: false });
  assert.equal(calls.length, 3);
  presentView(view, previous, { visible: true, bounds });
  assert.deepEqual(calls.at(-1), ['visible', true]);
  assert.equal(calls.length, 4);
});

test('inactive pages leave the native child hierarchy without destroying their retained view', () => {
  const calls = [];
  const children = new Set();
  const view = {
    setBounds: () => calls.push('bounds'),
    setVisible: (visible) => calls.push(visible ? 'show' : 'hide'),
  };
  const parent = {
    addChildView: (child) => {
      children.add(child);
      calls.push('attach');
    },
    removeChildView: (child) => {
      children.delete(child);
      calls.push('detach');
    },
  };
  const bounds = { x: 260, y: 60, width: 1000, height: 800 };
  let previous = presentView(view, { visible: false, attached: false }, { visible: true, bounds }, parent);
  assert.deepEqual(calls, ['attach', 'bounds', 'show']);
  for (let i = 0; i < 10; i++) previous = presentView(view, previous, { visible: true, bounds }, parent);
  assert.equal(calls.length, 3, 'Repeated publications keep the attached page stable');
  previous = presentView(view, previous, { visible: false }, parent);
  assert.equal(children.size, 0);
  assert.deepEqual(calls.slice(-2), ['hide', 'detach']);
  previous = presentView(view, previous, { visible: false }, parent);
  assert.equal(calls.length, 5);
  previous = presentView(view, previous, { visible: true, bounds }, parent);
  assert.equal(children.has(view), true);
  assert.equal(previous.attached, true);
  assert.deepEqual(calls.slice(-2), ['attach', 'show']);
  previous = presentView(view, previous, { visible: false, retainAttachment: true }, parent);
  assert.equal(children.has(view), true, 'An in-flight compositor copy retains only the native surface');
  assert.equal(previous.visible, false, 'Retaining the surface must not expose the page over the modal');
  previous = presentView(view, previous, { visible: false }, parent);
  assert.equal(children.size, 0, 'Settled or expired captures release their hidden surface');
  assert.equal(previous.attached, false);
});

test('focus can change split pane without swapping its visual position', () => {
  const tabs = [
    { id: 'a', spaceId: 'home', url: 'https://a.example/' },
    { id: 'b', spaceId: 'home', url: 'https://b.example/' },
  ];
  assert.deepEqual(resolveSplit(['a', 'b'], tabs, 'a', 'home'), { leftId: 'a', rightId: 'b', otherId: 'b' });
  assert.deepEqual(resolveSplit(['a', 'b'], tabs, 'b', 'home'), { leftId: 'a', rightId: 'b', otherId: 'a' });
  assert.equal(resolveSplit(['a', 'b'], tabs, 'c', 'home'), null);
  assert.equal(resolveSplit(['a', 'b'], tabs.slice(0, 1), 'a', 'home'), null);
  assert.equal(resolveSplit(['a', 'b'], tabs, 'a', 'work'), null);
});

test('saved maximized state preserves the normal window on its original monitor', () => {
  const placement = restoreWindowPlacement({ x: -1800, y: 100, width: 1200, height: 800, maximized: true }, [
    { x: 0, y: 0, width: 1920, height: 1040 },
    { x: -1920, y: 0, width: 1920, height: 1040 },
  ]);
  assert.deepEqual(placement, { x: -1800, y: 100, width: 1200, height: 800, maximized: true });
});

test('disconnected monitors and oversize windows restore completely on screen', () => {
  const placement = restoreWindowPlacement({ x: 5000, y: 4000, width: 2400, height: 1600 }, [
    { x: 0, y: 0, width: 1366, height: 768 },
  ]);
  assert.deepEqual(placement, { x: 0, y: 0, width: 1366, height: 768, maximized: false });
  const missing = restoreWindowPlacement({}, [{ x: 100, y: 50, width: 1920, height: 1080 }]);
  assert.deepEqual(missing, { x: 340, y: 120, width: 1440, height: 940, maximized: false });
});
