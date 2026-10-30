'use strict';

// Background transparency never fades text or the independent website views.
// Tint and the optional native blur are independent. At zero blur, macOS has
// no vibrancy layer, preserving genuinely clear window backgrounds.
function windowMaterial({
  platform,
  release = '',
  opacity = 100,
  blur = 0,
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
  const requestedBlur =
    typeof blur === 'number' && Number.isFinite(blur) ? Math.max(0, Math.min(32, blur)) : 0;
  const blurStrength = enabled && platform === 'darwin' ? requestedBlur / 32 : 0;
  return {
    supported,
    enabled,
    type: enabled
      ? platform === 'darwin'
        ? blurStrength
          ? 'vibrancy'
          : 'transparent'
        : 'acrylic'
      : 'opaque',
    opacity: enabled ? requestedOpacity : 100,
    requestedOpacity,
    requestedBlur,
    blurStrength,
    reason,
    blur: platform === 'darwin' ? (blurStrength ? 'system' : 'none') : 'system',
  };
}

module.exports = { windowMaterial };
