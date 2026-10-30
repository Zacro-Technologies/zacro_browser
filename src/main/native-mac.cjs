'use strict';

let bridge;
if (process.platform === 'darwin') {
  try {
    bridge = require('../native/macos-bridge.node');
  } catch (error) {
    console.warn('Native Mac controls unavailable:', error.message);
  }
}

const phaseName = (phase) =>
  phase & 16 ? 'cancelled' : phase & 8 ? 'ended' : phase & 1 ? 'began' : phase & 6 ? 'changed' : undefined;

function startMacScrollMonitor(window, onScroll) {
  if (!bridge || !window || window.isDestroyed()) return null;
  let stopped = false;
  const id = bridge.monitorScroll(window.getNativeWindowHandle(), (sample) => {
    if (stopped || window.isDestroyed()) return;
    onScroll({
      ...sample,
      phase: phaseName(sample.phase),
      momentum: sample.momentumPhase !== 0,
      momentumEnded: Boolean(sample.momentumPhase & 24),
      deltaMode: sample.precise ? 0 : 1,
    });
  });
  if (!id) return null;
  return () => {
    if (stopped) return;
    stopped = true;
    bridge.stopScroll(id);
  };
}

function setMacBlurStrength(window, strength) {
  return Boolean(
    bridge &&
    window &&
    !window.isDestroyed() &&
    bridge.setBlurStrength(window.getNativeWindowHandle(), Math.max(0, Math.min(1, strength))),
  );
}

function performMacHaptic(pattern) {
  if (!bridge || !['alignment', 'levelChange'].includes(pattern)) return false;
  bridge.performHaptic(pattern === 'alignment' ? 0 : 1);
  return true;
}

module.exports = { startMacScrollMonitor, setMacBlurStrength, performMacHaptic };
