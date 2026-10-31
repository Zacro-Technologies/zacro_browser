'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  browserLayout,
  peekMotionBounds,
  presentView,
  resolveSplit,
  restoreWindowPlacement,
} = require('../src/main/layout.cjs');

test('native pages align with compact chrome, sidebar, and open panels without fractional seams', () => {
  const layout = browserLayout({
    pageGutter: 8,
    width: 1441,
    height: 941,
    sidebarWidth: 260,
    panelWidth: 400,
    split: true,
  });
  assert.deepEqual(layout.primary, { x: 268, y: 36, width: 379, height: 897 });
  assert.deepEqual(layout.secondary, { x: 653, y: 36, width: 380, height: 897 });
  assert.equal(layout.secondary.x + layout.secondary.width + 400 + 8, 1441);
  assert.equal(layout.secondary.x - layout.primary.x - layout.primary.width, 6);
  assert.deepEqual(layout.peek, { x: 360, y: 72, width: 581, height: 825 });
});

test('hiding the sidebar reclaims its width while keeping the page, panel and split frame aligned', () => {
  const full = browserLayout({ pageGutter: 8, width: 1000, height: 700, sidebarWidth: 0, contentTop: 40 });
  assert.deepEqual(full.primary, { x: 8, y: 40, width: 984, height: 652 });
  assert.equal(full.secondary, null);
  assert.deepEqual(full.peek, { x: 120, y: 66, width: 760, height: 600 });

  const split = browserLayout({
    pageGutter: 8,
    width: 1000,
    height: 700,
    sidebarWidth: 0,
    contentTop: 40,
    panelWidth: 360,
    split: true,
  });
  assert.deepEqual(split.primary, { x: 8, y: 40, width: 309, height: 652 });
  assert.deepEqual(split.secondary, { x: 323, y: 40, width: 309, height: 652 });
  assert.equal(split.secondary.x + split.secondary.width + 360 + 8, 1000);
  assert.deepEqual(split.peek, { x: 83, y: 66, width: 474, height: 600 });

  const restored = browserLayout({ pageGutter: 8, width: 1000, height: 700, sidebarWidth: 300 });
  assert.equal(
    restored.primary.x,
    308,
    'A custom sidebar width retains the same page inset after focus mode',
  );
  assert.equal(browserLayout({ pageGutter: 8, width: 1000, height: 700 }).primary.x, 232);
});

test('sidebar navigation, caption rail and Find reserve only their supported content insets', () => {
  for (const contentTop of [8, 36, 40]) {
    const layout = browserLayout({ pageGutter: 8, width: 1001, height: 701, sidebarWidth: 224, contentTop });
    assert.equal(layout.primary.y, contentTop);
    assert.equal(layout.primary.y + layout.primary.height, 693, 'The page retains its 8px bottom frame');
    assert(layout.peek.y >= contentTop + 20, 'Peek leaves a small vertical margin');
    assert(layout.peek.y + layout.peek.height <= 673, 'Peek leaves the surrounding page exposed');
    assert(
      layout.peek.x + layout.peek.width + 40 <= layout.primary.x + layout.primary.width,
      'Right-side controls stay inside the content pane',
    );
  }
  for (const contentTop of [-1, 0, 8.5, 44, 10000, NaN, Infinity])
    assert.equal(browserLayout({ pageGutter: 8, width: 1000, height: 700, contentTop }).primary.y, 36);
  for (const [sidebarWidth, expected] of [
    [100, 108],
    [224, 232],
    [300, 308],
    [400, 388],
  ])
    assert.equal(
      browserLayout({ pageGutter: 8, width: 1000, height: 700, sidebarWidth }).primary.x,
      expected,
    );
});

test('custom gutters stay equal throughout the sidebar animation and split layouts', () => {
  const defaults = browserLayout({ width: 1000, height: 700, contentTop: 4 });
  assert.deepEqual(defaults.primary, { x: 228, y: 4, width: 768, height: 692 });
  for (const pageGutter of [4, 8, 12, 20])
    for (const sidebarWidth of [0, 7, 80, 160, 224, 236, 380]) {
      const result = browserLayout({
        width: 1440,
        height: 900,
        sidebarWidth,
        pageGutter,
        contentTop: pageGutter,
        split: true,
      });
      assert.equal(result.primary.x - sidebarWidth, pageGutter);
      assert.equal(result.primary.y, pageGutter);
      assert.equal(900 - result.primary.y - result.primary.height, pageGutter);
      assert.equal(1440 - result.secondary.x - result.secondary.width, pageGutter);
      assert.equal(result.secondary.x - result.primary.x - result.primary.width, 6);
    }
});

test('resizing and malformed dimensions keep native bounds finite and positive', () => {
  for (const width of [560, 640, 800, 960, 1100, 1440, 3840, NaN]) {
    const layout = browserLayout({
      pageGutter: 8,
      width,
      height: 420,
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

test('split ratios resize both pages without seams and retain usable pane widths', () => {
  for (const width of [560, 1000, 1800]) {
    for (const splitRatio of [0, 0.1, 0.25, 0.5, 0.7, 0.9, 1, NaN, Infinity]) {
      const layout = browserLayout({
        pageGutter: 8,
        width,
        height: 700,
        sidebarWidth: 224,
        split: true,
        splitRatio,
      });
      assert.equal(layout.secondary.x - layout.primary.x - layout.primary.width, 6);
      assert.equal(layout.secondary.x + layout.secondary.width, width - 8);
      const minimum = Math.min(160, Math.floor((width - 224 - 16 - 6) / 2));
      assert(layout.primary.width >= minimum);
      assert(layout.secondary.width >= minimum);
    }
  }
  const left = browserLayout({ pageGutter: 8, width: 1400, height: 700, split: true, splitRatio: 0.7 });
  assert.equal(left.primary.width, Math.floor((1400 - 224 - 16 - 6) * 0.7));
  assert(left.primary.width > left.secondary.width);
});

test('small windows reserve a usable page and remember their actual size', () => {
  const expanded = browserLayout({ pageGutter: 8, width: 560, height: 420, sidebarWidth: 380 });
  assert.deepEqual(expanded.primary, { x: 312, y: 36, width: 240, height: 376 });
  const panel = browserLayout({
    pageGutter: 8,
    width: 560,
    height: 420,
    sidebarWidth: 0,
    panelWidth: 304,
    contentTop: 40,
  });
  assert.deepEqual(panel.primary, { x: 8, y: 40, width: 240, height: 372 });
  assert.deepEqual(
    restoreWindowPlacement({ x: 50, y: 80, width: 560, height: 420 }, [
      { x: 0, y: 0, width: 1920, height: 1080 },
    ]),
    { x: 50, y: 80, width: 560, height: 420, maximized: false },
  );
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
  assert.equal(resolveSplit(['a', 'b'], [tabs[0], { ...tabs[1], closed: true }], 'a', 'home'), null);
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

test('Peek grows from the link and expands to full size without changing page zoom', () => {
  const target = { x: 300, y: 100, width: 700, height: 600 };
  const origin = { x: 400, y: 300, width: 40, height: 30 };
  const full = { x: 230, y: 8, width: 920, height: 800 };
  assert.deepEqual(peekMotionBounds(target, origin, 0, 'opening', full), origin);
  assert.deepEqual(peekMotionBounds(target, origin, 1, 'opening', full), target);
  assert.deepEqual(peekMotionBounds(target, origin, 0, 'expanding', full), target);
  assert.deepEqual(peekMotionBounds(target, origin, 1, 'expanding', full), full);
  const middle = peekMotionBounds(target, origin, 0.5, 'expanding', full);
  assert(middle.width > target.width && middle.width < full.width);
});
