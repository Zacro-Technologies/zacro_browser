const root = document.documentElement;
const surface = document.getElementById('surface');
const controls = document.getElementById('controls');
const sidebarToggle = document.getElementById('sidebar-toggle');
const veil = document.getElementById('veil');
const error = document.getElementById('error');
const errorMessage = document.getElementById('error-message');
let state = null;
let outsidePress = null;
const number = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback);
const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));

window.peekOverlay.onState((next) => {
  if (state?.id !== next?.id || state?.mode !== next?.mode) outsidePress = null;
  state = next;
  const sidebarMode = next?.mode === 'sidebar';
  root.dataset.mode = sidebarMode ? 'sidebar' : 'peek';
  document.title = sidebarMode ? 'Show sidebar' : 'Link preview';
  document.body.setAttribute('role', sidebarMode ? 'toolbar' : 'dialog');
  document.body.setAttribute('aria-label', sidebarMode ? 'Browser controls' : 'Link preview');
  if (sidebarMode) document.body.removeAttribute('aria-modal');
  else document.body.setAttribute('aria-modal', 'true');
  sidebarToggle.hidden = !(sidebarMode || next?.sidebarHidden);
  veil.hidden = surface.hidden = controls.hidden = sidebarMode;
  for (const key of ['chrome', 'card', 'ink']) {
    const value = next?.appearance?.[key];
    if (typeof value === 'string' && /^#(?:[\da-f]{3}|[\da-f]{6}|[\da-f]{8})$/i.test(value))
      root.style.setProperty(`--${key}`, value);
  }
  if (sidebarMode) {
    root.style.setProperty('--fade', '1');
    return;
  }
  const bounds = next?.bounds;
  if (!bounds) {
    root.style.setProperty('--fade', '0');
    return;
  }
  const progress = clamp(number(next.progress, 1), 0, 1);
  const fade = next.phase === 'expanding' ? 1 - progress : progress;
  root.style.setProperty('--fade', String(fade));
  root.dataset.phase = next.phase || 'open';
  root.style.setProperty('--radius', `${clamp(number(next.appearance?.radius, 12), 0, 40)}px`);
  Object.assign(surface.style, {
    left: `${number(bounds.x)}px`,
    top: `${number(bounds.y)}px`,
    width: `${Math.max(0, number(bounds.width))}px`,
    height: `${Math.max(0, number(bounds.height))}px`,
  });
  Object.assign(controls.style, {
    left: `${number(bounds.x) + number(bounds.width) + 8}px`,
    top: `${number(bounds.y) + 8}px`,
  });
  for (const button of controls.querySelectorAll('button')) button.disabled = next.phase === 'expanding';
  error.hidden = !next.error;
  surface.classList.toggle('failed', Boolean(next.error));
  errorMessage.textContent = next.error ? String(next.error).slice(0, 500) : '';
});

const outside = (event) => {
  if (state?.mode === 'sidebar' || !state?.bounds || event.target.closest('button')) return false;
  const { x, y, width, height } = state.bounds;
  return event.clientX < x || event.clientX > x + width || event.clientY < y || event.clientY > y + height;
};
document.addEventListener('pointerdown', (event) => {
  outsidePress =
    event.button === 0 && outside(event) ? { id: event.pointerId, x: event.clientX, y: event.clientY } : null;
});
document.addEventListener('pointerup', (event) => {
  const press = outsidePress;
  outsidePress = null;
  if (
    press?.id === event.pointerId &&
    outside(event) &&
    Math.hypot(event.clientX - press.x, event.clientY - press.y) < 8
  )
    window.peekOverlay.act('close');
});
document.addEventListener('pointercancel', () => {
  outsidePress = null;
});
document.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (button && !button.disabled) window.peekOverlay.act(button.dataset.action);
});
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || state?.mode === 'sidebar') return;
  event.preventDefault();
  event.stopPropagation();
  window.peekOverlay.act('close');
});
