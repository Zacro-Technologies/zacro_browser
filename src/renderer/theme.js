// Keep custom colors decorative while text remains readable on every material
// blend. These foregrounds match styles.css; high-contrast mode strengthens them.
export const THEME_TEXT_COLORS = Object.freeze({
  light: Object.freeze({ ink: '#302f2d', muted: '#574c59', accentInk: '#ffffff' }),
  dark: Object.freeze({ ink: '#eeedeb', muted: '#bfb7c4', accentInk: '#2b1720' }),
});

// grain.svg has its own .7 opacity and the window paints it exactly once.
// Existing 0–100 choices keep their strength; 100–200 adds stronger texture.
export const THEME_GRAIN_MAX_OPACITY = 0.09;
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

// Interpolate in Oklab so equal gesture distances make perceptually even color
// changes. Readable surface/foreground tokens are derived from this color later;
// interpolating independently fitted foregrounds could lose their contrast.
function colorToLab(value) {
  const [r, g, b] = parseColor(value).map((channel) => {
    channel /= 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}
function labToColor([lightness, a, b]) {
  const l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (lightness - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return hex(
    [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
    ].map((channel) => {
      channel = clamp(channel, 0, 1);
      return 255 * (channel <= 0.0031308 ? channel * 12.92 : 1.055 * channel ** (1 / 2.4) - 0.055);
    }),
  );
}

/** A presentation-only Space appearance. Never write this blend into storage. */
export function blendSpaceAppearance(from = {}, to = {}, progress = 0) {
  const amount = clamp(Number.isFinite(progress) ? progress : 0, 0, 1);
  const color = (space, secondary = false) =>
    hex(parseColor(secondary ? space.theme?.secondaryColor : space.color, hex(parseColor(space.color))));
  const blendColor = (secondary) => {
    const first = color(from, secondary),
      second = color(to, secondary);
    if (amount === 0) return first;
    if (amount === 1) return second;
    return labToColor(mix(colorToLab(first), colorToLab(second), amount));
  };
  const number = (key, fallback, minimum, maximum) => {
    const read = (space) =>
      clamp(Number.isFinite(space.theme?.[key]) ? space.theme[key] : fallback, minimum, maximum);
    return read(from) * (1 - amount) + read(to) * amount;
  };
  return {
    color: blendColor(false),
    theme: {
      secondaryColor: blendColor(true),
      gradient: number('gradient', 50, 0, 100),
      grain: number('grain', 0, 0, 200),
      opacity: number('opacity', 100, 0, 100),
    },
  };
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
  // Any blend of bounded colors stays inside these channel bounds, including
  // the strongest noise layer. Desktop content through glass is OS-controlled.
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
 * The guarantee covers opaque tint surfaces, arbitrary gradient interpolation
 * and the shell's single grain layer, not arbitrary desktop content under glass.
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
  const grainOpacity = (clamp(Number.isFinite(grain) ? grain : 0, 0, 200) / 200) * THEME_GRAIN_MAX_OPACITY;
  const noiseAlpha = grainOpacity * GRAIN_SOURCE_OPACITY;
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
