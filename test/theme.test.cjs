'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const modulePromise = import('../src/renderer/theme.js');

// Independently evaluate WCAG contrast and painted alpha layers. Tests exercise
// the public CSS tokens rather than the helper's internal tone-fitting steps.
const channels = (value) => [1, 3, 5].map((index) => parseInt(value.slice(index, index + 2), 16));
const overlay = (background, color, opacity) =>
  background.map((channel, index) => color[index] * opacity + channel * (1 - opacity));
function relativeLuminance(color) {
  const linear = color
    .map((channel) => channel / 255)
    .map((channel) => (channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4));
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
function ratio(first, second) {
  const light = Math.max(relativeLuminance(first), relativeLuminance(second));
  const dark = Math.min(relativeLuminance(first), relativeLuminance(second));
  return (light + 0.05) / (dark + 0.05);
}

test('Space tones cover extreme and saturated custom colors, all blends, transparency and two grain layers', async () => {
  const { deriveSpaceTheme, THEME_TEXT_COLORS } = await modulePromise;
  const colors = [
    '#000000',
    '#ffffff',
    '#ff0000',
    '#00ff00',
    '#0000ff',
    '#ffff00',
    '#00ffff',
    '#ff00ff',
    '#9d4460',
    '#786298',
    '#6192bd',
    '#4f9485',
  ];
  for (const dark of [false, true]) {
    const text = THEME_TEXT_COLORS[dark ? 'dark' : 'light'];
    for (const color of colors)
      for (const secondaryColor of colors)
        for (const grain of [0, 50, 100]) {
          const tokens = deriveSpaceTheme({ color, secondaryColor, dark, grain });
          const primary = channels(tokens.tintPrimary),
            secondary = channels(tokens.tintSecondary),
            chrome = channels(tokens.chrome);
          const normal = [channels(text.ink), channels(text.muted), channels(tokens.accent)];
          const noiseOpacity = tokens.grainOpacity * 0.7;
          const context = `${dark ? 'dark' : 'light'} ${color}/${secondaryColor} grain ${grain}`;
          for (const blend of [0, 0.25, 0.5, 0.75, 1])
            for (const opacity of [0.4, 0.6, 0.8, 1]) {
              const gradient = overlay(primary, secondary, blend);
              for (const noise of [
                [0, 0, 0],
                [255, 255, 255],
              ]) {
                // App grain is behind the translucent sidebar; sidebar grain is in
                // front. This covers stronger interference than average noise.
                const appGrain = overlay(gradient, noise, noiseOpacity);
                const glass = overlay(appGrain, chrome, opacity);
                const painted = overlay(glass, noise, noiseOpacity);
                for (const foreground of normal)
                  assert(
                    ratio(foreground, painted) >= 4.5,
                    `${context}: text contrast ${ratio(foreground, painted)}`,
                  );
              }
            }
          for (const background of ['chrome', 'tintPrimary', 'tintSecondary', 'hover', 'accentSoft'])
            assert(
              ratio(channels(tokens.accent), channels(tokens[background])) >= 4.5,
              `${context}: accent on ${background}`,
            );
          assert(
            ratio(channels(text.accentInk), channels(tokens.accent)) >= 4.5,
            `${context}: primary button text`,
          );
        }
  }
});

test('Space tones remain safe across the RGB cube without washing all hues into one theme', async () => {
  const { deriveSpaceTheme, THEME_TEXT_COLORS } = await modulePromise;
  for (const dark of [false, true]) {
    const rendered = new Set();
    for (const r of [0, 64, 128, 192, 255])
      for (const g of [0, 64, 128, 192, 255])
        for (const b of [0, 64, 128, 192, 255]) {
          const color = '#' + [r, g, b].map((value) => value.toString(16).padStart(2, '0')).join('');
          const tokens = deriveSpaceTheme({ color, secondaryColor: color, dark, grain: 100 });
          rendered.add(tokens.tintPrimary);
          for (const key of ['chrome', 'tintPrimary', 'tintSecondary', 'hover', 'accentSoft']) {
            const background = channels(tokens[key]);
            const noise = Array(3).fill(dark ? 255 : 0);
            const worst = overlay(
              overlay(background, noise, tokens.grainOpacity * 0.7),
              noise,
              tokens.grainOpacity * 0.7,
            );
            assert(
              ratio(channels(THEME_TEXT_COLORS[dark ? 'dark' : 'light'].muted), worst) >= 4.5,
              `${color} ${key}`,
            );
            assert(ratio(channels(tokens.accent), worst) >= 4.5, `${color} accent on noisy ${key}`);
          }
        }
    assert(rendered.size >= 100, 'Custom themes must retain distinct color choices');
  }
});

test('Space tone defaults are deterministic and malformed colors or grain cannot produce invalid CSS', async () => {
  const { deriveSpaceTheme, THEME_GRAIN_MAX_OPACITY } = await modulePromise;
  assert.deepEqual(
    deriveSpaceTheme({ color: '#abc' }),
    deriveSpaceTheme({ color: '#aabbcc', secondaryColor: '#aabbcc' }),
  );
  assert.deepEqual(
    deriveSpaceTheme({ color: 'url(secret)', secondaryColor: '<script>', grain: NaN }),
    deriveSpaceTheme(),
  );
  for (const grain of [-Infinity, -1, 0, NaN, '100', 100, 10000, Infinity]) {
    const tokens = deriveSpaceTheme({ grain });
    for (const [name, value] of Object.entries(tokens)) {
      if (name === 'grainOpacity')
        assert(Number.isFinite(value) && value >= 0 && value <= THEME_GRAIN_MAX_OPACITY);
      else assert.match(value, /^#[\da-f]{6}$/);
    }
  }
  assert.equal(deriveSpaceTheme({ grain: 100 }).grainOpacity, THEME_GRAIN_MAX_OPACITY);
  assert.equal(deriveSpaceTheme({ grain: 0 }).grainOpacity, 0);
  assert.equal(deriveSpaceTheme({ grain: 10000 }).grainOpacity, THEME_GRAIN_MAX_OPACITY);
});

test('The contrast budget tracks the actual shell text and texture source colors', async () => {
  const { THEME_TEXT_COLORS } = await modulePromise;
  const css = await fs.readFile(path.resolve(__dirname, '../src/renderer/styles.css'), 'utf8');
  const grain = await fs.readFile(path.resolve(__dirname, '../src/renderer/grain.svg'), 'utf8');
  for (const palette of Object.values(THEME_TEXT_COLORS))
    for (const [name, color] of Object.entries(palette)) {
      const property = name === 'accentInk' ? 'accent-ink' : name;
      const equivalent = color === '#ffffff' ? '#(?:fff|ffffff)' : color;
      assert.match(css, new RegExp(`--${property}:\\s*${equivalent}\\s*;`));
    }
  assert.match(grain, /opacity="\.7"/);
});
