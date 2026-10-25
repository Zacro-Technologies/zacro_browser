// WheelEvent does not expose portable native begin/end phases. Treat an
// uninterrupted stream as one gesture; an explicit momentum flag, where the
// browser supports it, gives a stronger signal than the quiet-period fallback.
export const SPACE_GESTURE_IDLE_MS = 240;

const finite = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback);
const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

/**
 * Pure, clock-injected wheel recognizer. No DOM access, timers or navigation.
 *
 * update receives wheel fields plus {time, width, index, count, contextKey,
 * blocked}. The caller owns hit testing and marks inputs, nested horizontal
 * scrollers, browser controls, dialogs, dragging and native-page events blocked.
 *
 * The result contains a one-shot commit (-1/0/1), targetIndex, preventDefault,
 * and tracking feedback: offset in CSS pixels, progress 0..1, direction, atEdge.
 * Positive deltaX selects the next Space and moves the current list left.
 * Reset an idle timer to idleDelay after each event, then call settle(time).
 * interrupt(time) cancels feedback and consumes the remainder of the stream.
 */
export function createSpaceGesture() {
  const threshold = 64;
  const axisSlop = 8;
  const axisRatio = 1.5;
  const flickDistance = 44;
  const flickVelocity = 0.75;
  const flickWindow = 100;
  let lastTime = -Infinity;
  let context;
  let origin = -1;
  let count = 0;
  let phase = 'idle';
  let distance = 0;
  let horizontal = 0;
  let vertical = 0;
  let samples = [];
  let explicitMomentum = false;

  const neutral = (overrides = {}) => ({
    preventDefault: false,
    offset: 0,
    progress: 0,
    direction: 0,
    targetIndex: null,
    commit: 0,
    atEdge: false,
    phase,
    idleDelay: phase === 'idle' ? 0 : SPACE_GESTURE_IDLE_MS,
    ...overrides,
  });
  const clear = () => {
    phase = 'idle';
    distance = horizontal = vertical = 0;
    samples = [];
    explicitMomentum = false;
  };
  const feedback = (preventDefault = false) => {
    if (phase !== 'tracking') return neutral({ preventDefault });
    const direction = Math.sign(distance);
    const next = origin + direction;
    const atEdge = Boolean(direction && (next < 0 || next >= count));
    // Resistance at an endpoint is bounded and never wraps into another profile.
    const amount = Math.abs(distance);
    const offset = atEdge ? (-direction * 24 * amount) / (40 + amount) : distance ? -distance : 0;
    return neutral({
      preventDefault,
      offset,
      progress: Math.min(1, amount / threshold),
      direction,
      targetIndex: direction && !atEdge ? next : null,
      atEdge,
      phase: atEdge ? 'edge' : 'tracking',
    });
  };
  const interrupt = (time) => {
    lastTime = Math.max(finite(time, finite(lastTime)), finite(lastTime));
    clear();
    phase = 'blocked';
    return neutral();
  };

  function update(input = {}) {
    const time = Math.max(finite(input.time, finite(lastTime)), finite(lastTime));
    const width = Math.max(1, finite(input.width, 224));
    const scale = input.deltaMode === 1 ? 16 : input.deltaMode === 2 ? width : 1;
    const shift = input.shiftKey && !finite(input.deltaX);
    const dx = finite(shift ? input.deltaY : input.deltaX) * scale;
    const dy = shift ? 0 : finite(input.deltaY) * scale;
    const nextCount = Math.max(0, Math.floor(finite(input.count)));
    const nextIndex = Number.isInteger(input.index) ? input.index : -1;
    const blocked = Boolean(
      input.blocked ||
      input.buttons ||
      input.defaultPrevented ||
      input.ctrlKey ||
      input.metaKey ||
      input.altKey ||
      nextCount < 2 ||
      nextIndex < 0 ||
      nextIndex >= nextCount,
    );
    if (blocked) return interrupt(time);
    if (!dx && !dy) return feedback();

    const quiet = time - lastTime >= SPACE_GESTURE_IDLE_MS;
    const freshContact = explicitMomentum && input.momentum === false;
    if (quiet || freshContact) clear();
    else if (
      context !== input.contextKey ||
      ((phase === 'tracking' || phase === 'pending') && (origin !== nextIndex || count !== nextCount))
    ) {
      // A profile or externally selected Space changed during the stream.
      // Its remaining wheel events must not navigate the new context.
      return interrupt(time);
    }
    context = input.contextKey;
    lastTime = time;

    if (input.momentum === true) {
      const claimed = phase === 'tracking' || phase === 'locked';
      clear();
      phase = 'locked';
      explicitMomentum = true;
      return neutral({ preventDefault: claimed || (dx !== 0 && Math.abs(dx) >= Math.abs(dy) * axisRatio) });
    }
    if (phase === 'blocked' || phase === 'vertical') return neutral();
    if (phase === 'locked')
      return neutral({ preventDefault: dx !== 0 && Math.abs(dx) >= Math.abs(dy) * axisRatio });
    if (phase === 'idle') {
      origin = nextIndex;
      count = nextCount;
      phase = 'pending';
    }

    horizontal += Math.abs(dx);
    vertical += Math.abs(dy);
    distance += dx;
    if (phase === 'pending') {
      if (vertical >= axisSlop && horizontal < vertical * axisRatio) {
        phase = 'vertical';
        distance = 0;
        return neutral();
      }
      if (horizontal < axisSlop || horizontal < vertical * axisRatio) return neutral();
      phase = 'tracking';
    }

    // A reversal unwinds the existing displacement rather than jumping to a
    // different preview. Discard its prior velocity so it cannot create a flick.
    if (dx && samples.length && Math.sign(dx) !== Math.sign(samples.at(-1).dx)) samples = [];
    if (dx) samples.push({ time, dx });
    samples = samples.filter((sample) => time - sample.time <= flickWindow);
    const direction = Math.sign(distance);
    const target = origin + direction;
    if (target < 0 || target >= count) {
      distance = clamp(distance, -threshold * 1.5, threshold * 1.5);
      return feedback(true);
    }
    const elapsed = samples.length > 1 ? time - samples[0].time : 0;
    const velocity = elapsed > 0 ? samples.reduce((total, sample) => total + sample.dx, 0) / elapsed : 0;
    const flick =
      Math.abs(distance) >= flickDistance &&
      elapsed >= 12 &&
      Math.abs(velocity) >= flickVelocity &&
      Math.sign(velocity) === direction &&
      Math.sign(dx) === direction;
    if (Math.abs(distance) >= threshold || flick) {
      const result = feedback(true);
      phase = 'locked';
      distance = 0;
      samples = [];
      return {
        ...result,
        phase: 'committed',
        progress: 1,
        commit: direction,
        offset: -direction * threshold,
      };
    }
    return feedback(true);
  }

  function settle(time) {
    const remaining = SPACE_GESTURE_IDLE_MS - (finite(time, finite(lastTime)) - lastTime);
    if (remaining > 0 && phase !== 'idle') return { ...feedback(), idleDelay: Math.ceil(remaining) };
    clear();
    return neutral();
  }

  return { update, settle, interrupt };
}
