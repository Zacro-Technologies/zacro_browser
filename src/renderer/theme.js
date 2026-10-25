// Keep custom colors decorative while text remains readable on every material
// blend. These foregrounds match styles.css; high-contrast mode strengthens them.
export const THEME_TEXT_COLORS = Object.freeze({
  light: Object.freeze({ ink: '#302f2d', muted: '#574c59', accentInk: '#ffffff' }),
  dark: Object.freeze({ ink: '#eeedeb', muted: '#bfb7c4', accentInk: '#2b1720' }),
});

// grain.svg has its own .7 opacity. Both the app and sidebar can paint a layer.
// Budget for black/white noise at both layers, not merely average gray noise.
export const THEME_GRAIN_MAX_OPACITY = 0.045;
const GRAIN_SOURCE_OPACITY = 0.7;

const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const mix = (first, second, amount) =>
  first.map((channel, index) => channel * (1 - amount) + second[index] * amount);
const hex = (value) =>
  '#' + value.map((channel) => Math.round(channel).toString(16).padStart(2, '0')).join('');

function parseColor(value, fallback = '#9d4460') {
  if (typeof value === 'string' && /^#[\da-f]{3}$/i.test(value))
    value = '#' + [...value.slice(1)].map((channel) => channel + channel).join('');
  if (typeof value !== 'string' || !/^#[\da-f]{6}$/i.test(value)) value = fallback;
  return [1, 3, 5].map((index) => parseInt(value.slice(index, index + 2), 16));
}

function luminance(value) {
  return value.reduce((sum, channel, index) => {
    const normalized = channel / 255;
    const linear = normalized <= 0.04045 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
    return sum + linear * [0.2126, 0.7152, 0.0722][index];
  }, 0);
}

function contrast(first, second) {
  const a = luminance(first),
    b = luminance(second);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

function boundTone(value, dark) {
  // Any blend of bounded colors stays inside these channel bounds. Even two
  // full-strength noise layers retain >4.6:1 against the normal muted text.
  const edge = dark ? Math.max(...value) : Math.min(...value);
  const amount = dark ? (edge > 61 ? 1 - 61 / edge : 0) : edge < 208 ? (208 - edge) / (255 - edge) : 0;
  return mix(value, dark ? [0, 0, 0] : [255, 255, 255], amount).map((channel) =>
    dark ? Math.floor(channel) : Math.ceil(channel),
  );
}

function readableAccent(value, backgrounds, accentInk, dark) {
  const valid = (candidate) =>
    contrast(candidate, accentInk) >= 4.5 &&
    backgrounds.every((background) => contrast(candidate, background) >= 4.5);
  value = value.map(Math.round);
  if (valid(value)) return value;
  const endpoint = dark ? [255, 255, 255] : [0, 0, 0];
  let low = 0,
    high = 1;
  for (let step = 0; step < 24; step++) {
    const middle = (low + high) / 2;
    const candidate = mix(value, endpoint, middle).map(Math.round);
    if (valid(candidate)) high = middle;
    else low = middle;
  }
  return mix(value, endpoint, high).map(Math.round);
}

/**
 * CSS-ready material colors for an arbitrary Space color pair. Wire chrome,
 * tintPrimary/tintSecondary, hover, accent, accentSoft and grainOpacity directly
 * to CSS variables; do not mix the unbounded input colors back into text surfaces.
 * The guarantee covers normal opaque text, sidebar opacity 40–100%, arbitrary
 * gradient interpolation and the two grain.svg layers used by the shell.
 */
export function deriveSpaceTheme({ color, secondaryColor, dark = false, grain = 0 } = {}) {
  const primary = parseColor(color);
  const secondary = parseColor(secondaryColor, hex(primary));
  const surface = parseColor(dark ? '#222425' : '#f8f7f4');
  const card = parseColor(dark ? '#363839' : '#ffffff');
  const chrome = boundTone(mix(parseColor(dark ? '#28262d' : '#e9e5e9'), primary, dark ? 0.18 : 0.19), dark);
  const tintPrimary = boundTone(mix(surface, primary, 0.3), dark);
  const tintSecondary = boundTone(mix(surface, secondary, 0.28), dark);
  const hover = boundTone(mix(parseColor(dark ? '#343637' : '#deddd8'), primary, dark ? 0.06 : 0.05), dark);
  const accentSoft = boundTone(
    dark ? primary.map((channel) => channel * 0.35 + 25) : mix([255, 255, 255], primary, 0.15),
    dark,
  );
  const grainOpacity = (clamp(Number.isFinite(grain) ? grain : 0, 0, 100) / 100) * THEME_GRAIN_MAX_OPACITY;
  const noiseAlpha = 1 - (1 - grainOpacity * GRAIN_SOURCE_OPACITY) ** 2;
  const backgrounds = [chrome, tintPrimary, tintSecondary, hover, accentSoft, surface, card].flatMap(
    (background) => [mix(background, [0, 0, 0], noiseAlpha), mix(background, [255, 255, 255], noiseAlpha)],
  );
  const accent = readableAccent(
    dark ? mix(primary, [255, 255, 255], 0.48) : primary,
    backgrounds,
    parseColor(THEME_TEXT_COLORS[dark ? 'dark' : 'light'].accentInk),
    dark,
  );
  return {
    chrome: hex(chrome),
    tintPrimary: hex(tintPrimary),
    tintSecondary: hex(tintSecondary),
    hover: hex(hover),
    accent: hex(accent),
    accentSoft: hex(accentSoft),
    grainOpacity,
  };
}
