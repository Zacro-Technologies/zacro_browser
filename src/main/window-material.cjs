'use strict';

// Native materials blur the desktop behind the window. They do not change the
// opacity of text or the independent Chromium surfaces that render websites.
function windowMaterial({
  platform,
  release = '',
  opacity = 100,
  reducedTransparency = false,
  highContrast = false,
} = {}) {
  const requestedOpacity =
    typeof opacity === 'number' && Number.isFinite(opacity)
      ? Math.round(Math.max(40, Math.min(100, opacity)))
      : 100;
  const windowsBuild = Number(String(release).split('.')[2]);
  const supported = platform === 'darwin' || (platform === 'win32' && windowsBuild >= 22621);
  const reason = highContrast
    ? 'high-contrast'
    : reducedTransparency
      ? 'reduced-transparency'
      : !supported
        ? 'unsupported-platform'
        : requestedOpacity === 100
          ? 'opaque'
          : null;
  const enabled = reason === null;
  return {
    supported,
    enabled,
    type: enabled ? (platform === 'darwin' ? 'vibrancy' : 'acrylic') : 'opaque',
    opacity: enabled ? requestedOpacity : 100,
    requestedOpacity,
    reason,
    blur: 'system',
  };
}

module.exports = { windowMaterial };
