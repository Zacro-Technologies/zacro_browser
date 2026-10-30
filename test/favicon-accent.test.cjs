'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const modulePromise = import('../src/renderer/favicon-accent.js');
const pixels = (...groups) =>
  new Uint8ClampedArray(
    groups.flatMap(([color, count]) => Array.from({ length: count }, () => color).flat()),
  );

test('favicon accent follows the dominant logo color instead of white, black or transparent padding', async () => {
  const { faviconAccent } = await modulePromise;
  assert.equal(
    faviconAccent(
      pixels(
        [[255, 255, 255, 255], 300],
        [[0, 0, 0, 255], 300],
        [[255, 0, 0, 0], 300],
        [[35, 105, 220, 255], 80],
        [[230, 40, 30, 255], 20],
      ),
    ),
    '#2369dc',
  );
  assert.equal(faviconAccent(pixels([[240, 40, 40, 255], 80], [[35, 105, 220, 255], 20])), '#f02828');
});

test('monochrome and empty icons use the Space accent fallback', async () => {
  const { faviconAccent } = await modulePromise;
  assert.equal(faviconAccent(new Uint8ClampedArray()), null);
  assert.equal(
    faviconAccent(pixels([[240, 240, 240, 255], 200], [[10, 10, 10, 255], 200], [[120, 125, 120, 255], 200])),
    null,
  );
});
