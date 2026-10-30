'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { windowMaterial } = require('../src/main/window-material.cjs');

test('native glass is available only on supported native compositors', () => {
  assert.deepEqual(windowMaterial({ platform: 'win32', release: '10.0.22621', opacity: 65 }), {
    supported: true,
    enabled: true,
    type: 'acrylic',
    opacity: 65,
    requestedOpacity: 65,
    requestedBlur: 0,
    blurStrength: 0,
    reason: null,
    blur: 'system',
  });
  for (const opacity of [0, 1, 25, 50, 75, 99]) {
    const material = windowMaterial({ platform: 'darwin', release: '24.0.0', opacity });
    assert.equal(material.type, 'transparent');
    assert.equal(material.opacity, opacity);
    assert.equal(material.blur, 'none', 'macOS does not add a fixed-opacity vibrancy layer');
  }
  for (const release of ['10.0.19045', '10.0.22000', 'not-a-version', '']) {
    const material = windowMaterial({ platform: 'win32', release, opacity: 40 });
    assert.equal(material.enabled, false);
    assert.equal(material.opacity, 100);
    assert.equal(material.reason, 'unsupported-platform');
  }
  assert.equal(windowMaterial({ platform: 'linux', opacity: 65 }).reason, 'unsupported-platform');
});

test('Mac blur strength is independent of tint and disabled by accessibility or opaque chrome', () => {
  for (const opacity of [0, 25, 50, 99]) {
    for (const blur of [0, 8, 16, 32]) {
      const material = windowMaterial({ platform: 'darwin', opacity, blur });
      assert.equal(material.opacity, opacity);
      assert.equal(material.blurStrength, blur / 32);
      assert.equal(material.type, blur ? 'vibrancy' : 'transparent');
    }
  }
  for (const extra of [{ opacity: 100 }, { reducedTransparency: true }, { highContrast: true }]) {
    const material = windowMaterial({ platform: 'darwin', opacity: 0, blur: 32, ...extra });
    assert.equal(material.blurStrength, 0);
    assert.equal(material.requestedBlur, 32);
  }
  for (const blur of [NaN, Infinity, '16', -1])
    assert.equal(windowMaterial({ platform: 'darwin', opacity: 0, blur }).blurStrength, 0);
  assert.equal(windowMaterial({ platform: 'darwin', opacity: 0, blur: 100 }).blurStrength, 1);
});

test('system accessibility overrides glass while retaining the requested preference', () => {
  for (const platform of ['darwin', 'win32']) {
    const input = { platform, release: '10.0.26200', opacity: 40 };
    for (const condition of ['reducedTransparency', 'highContrast']) {
      const material = windowMaterial({ ...input, [condition]: true });
      assert.equal(material.type, 'opaque');
      assert.equal(material.opacity, 100);
      assert.equal(material.requestedOpacity, 40);
      assert.equal(material.reason, condition === 'highContrast' ? 'high-contrast' : 'reduced-transparency');
    }
    assert.equal(windowMaterial({ ...input, opacity: 100 }).reason, 'opaque');
  }
});

test('malformed opacity cannot accidentally make the window transparent', () => {
  for (const opacity of [NaN, Infinity, -Infinity, '40', null, {}, undefined]) {
    const material = windowMaterial({ platform: 'darwin', opacity });
    assert.equal(material.enabled, false);
    assert.equal(material.opacity, 100);
  }
  assert.equal(windowMaterial({ platform: 'darwin', opacity: -20 }).opacity, 0);
  assert.equal(windowMaterial({ platform: 'darwin', opacity: 0 }).enabled, true);
  assert.equal(windowMaterial({ platform: 'darwin', opacity: 120 }).enabled, false);
  assert.equal(windowMaterial({ platform: 'darwin', opacity: 60.8 }).opacity, 61);
});
