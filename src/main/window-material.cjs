'use strict';

// Background transparency never fades text or the independent website views.
// macOS vibrancy has a fixed opacity floor, so use an alpha-capable window and
// let the renderer control its tint continuously. Windows retains native blur.
function windowMaterial({
  platform,
  release = '',
  opacity = 100,
  reducedTransparency = false,
  highContrast = false,
} = {}) {
  const requestedOpacity =
    typeof opacity === 'number' && Number.isFinite(opacity)
      ? Math.round(Math.max(0, Math.min(100, opacity)))
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
    type: enabled ? (platform === 'darwin' ? 'transparent' : 'acrylic') : 'opaque',
    opacity: enabled ? requestedOpacity : 100,
    requestedOpacity,
    reason,
    blur: platform === 'darwin' ? 'none' : 'system',
  };
}

module.exports = { windowMaterial };
