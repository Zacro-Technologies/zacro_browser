// WheelEvent has no portable contact-end phase. End/momentum hints are used
// when supplied; other devices use a short release pause and conservative tail
// detection. The longer quiet period prevents one stream crossing two Spaces.
export const SPACE_GESTURE_IDLE_MS = 240;
export const SPACE_GESTURE_RELEASE_MS = 110;

const finite = (value, fallback = 0) => (Number.isFinite(value) ? value : fallback);
const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));

/** Clock-injected recognizer: update tracks; settle decides after release.
 * Input includes wheel fields, optional momentum/contact phase, time, width,
 * index/count, contextKey and blocked. No DOM or navigation happens here.
 * A release result has one commit (-1/0/1), fromOffset, destination offset,
 * duration and travel. Subsequent tail events cannot produce another commit.
 */
export function createSpaceGesture() {
  let lastTime = -Infinity;
  let context,
    origin = -1,
    count = 0,
    travel = 224;
  let phase = 'idle',
    distance = 0,
    horizontal = 0,
    vertical = 0;
  let samples = [],
    lastDx = 0,
    reverseDistance = 0;
  let momentumSeen = false,
    contactKnown = false,
    phaseKnown = false;
  let peak = 0,
    peakTime = 0,
    declining = 0;

  const neutral = (overrides = {}) => ({
    preventDefault: false,
    offset: 0,
    fromOffset: 0,
    progress: 0,
    direction: 0,
    targetIndex: null,
    originIndex: origin,
    contextKey: context,
    commit: 0,
    atEdge: false,
    phase,
    travel,
    duration: 0,
    idleDelay: phase === 'idle' ? 0 : SPACE_GESTURE_IDLE_MS,
    ...overrides,
  });
  const clear = () => {
    phase = 'idle';
    distance = horizontal = vertical = lastDx = reverseDistance = 0;
    samples = [];
    momentumSeen = contactKnown = phaseKnown = false;
    peak = declining = 0;
  };
  const feedback = (preventDefault = false) => {
    if (phase !== 'tracking') return neutral({ preventDefault });
    const direction = Math.sign(distance);
    const next = origin + direction;
    const atEdge = Boolean(direction && (next < 0 || next >= count));
    const amount = Math.abs(distance);
    const resisted = atEdge
      ? (24 * amount) / (40 + amount)
      : amount <= travel
        ? amount
        : travel + (24 * (amount - travel)) / (48 + amount - travel);
    return neutral({
      preventDefault,
      offset: direction ? -direction * resisted : 0,
      progress: Math.min(1, amount / travel),
      direction,
      targetIndex: direction && !atEdge ? next : null,
      atEdge,
      phase: atEdge ? 'edge' : 'tracking',
      idleDelay: SPACE_GESTURE_RELEASE_MS,
    });
  };
  const velocity = () => {
    if (samples.length < 2) return 0;
    const span = samples.at(-1).time - samples[0].time;
    return span >= 8 ? clamp((samples.at(-1).position - samples[0].position) / span, -2.5, 2.5) : 0;
  };
  const release = (reason, preventDefault = false, cancelled = false) => {
    const view = feedback(preventDefault);
    const speed = velocity();
    const amount = Math.abs(distance);
    const reversing = reverseDistance >= travel * 0.08 && Math.sign(lastDx) !== view.direction;
    const flick =
      amount >= travel * 0.12 &&
      Math.sign(speed) === view.direction &&
      Math.abs(speed) >= 0.55 &&
      amount + Math.abs(speed) * 110 >= travel * 0.5;
    const commit =
      !cancelled && !reversing && view.targetIndex !== null && (amount >= travel * 0.42 || flick)
        ? view.direction
        : 0;
    const destination = commit ? -commit * travel : 0;
    const remaining = Math.abs(destination - view.offset) / travel;
    const duration = Math.round(
      commit
        ? clamp(140 + remaining * 100 - Math.abs(speed) * 24, 140, 240)
        : clamp(100 + remaining * 100, 100, 200),
    );
    phase = 'locked';
    samples = [];
    return {
      ...view,
      phase: commit ? 'committed' : 'settling',
      commit,
      targetIndex: commit ? view.targetIndex : null,
      fromOffset: view.offset,
      offset: destination,
      duration,
      reason,
      idleDelay: SPACE_GESTURE_IDLE_MS,
    };
  };
  const interrupt = (time) => {
    const wasMomentum = momentumSeen;
    lastTime = Math.max(finite(time, finite(lastTime)), finite(lastTime));
    clear();
    momentumSeen = wasMomentum;
    phase = 'blocked';
    return neutral();
  };

  function update(input = {}) {
    const time = Math.max(finite(input.time, finite(lastTime)), finite(lastTime));
    const width = Math.max(1, finite(input.width, 224));
    const scale = input.deltaMode === 1 ? 16 : input.deltaMode === 2 ? width : 1;
    const shifted = input.shiftKey && !finite(input.deltaX);
    const dx = finite(shifted ? input.deltaY : input.deltaX) * scale;
    const dy = shifted ? 0 : finite(input.deltaY) * scale;
    const nextCount = Math.max(0, Math.floor(finite(input.count)));
    const nextIndex = Number.isInteger(input.index) ? input.index : -1;
    const began = input.phase === 'began' || input.phase === 'begin';
    const ended = input.phase === 'ended' || input.phase === 'end';
    const cancelled = input.phase === 'cancelled';
    const blocked =
      input.blocked ||
      input.buttons ||
      input.defaultPrevented ||
      input.ctrlKey ||
      input.metaKey ||
      input.altKey ||
      nextCount < 2 ||
      nextIndex < 0 ||
      nextIndex >= nextCount;
    if (blocked) return interrupt(time);
    const elapsed = time - lastTime;
    if (
      (!phaseKnown && elapsed >= SPACE_GESTURE_IDLE_MS) ||
      elapsed >= 750 ||
      began ||
      (momentumSeen && input.momentum === false)
    )
      clear();
    else if (
      context !== input.contextKey ||
      ((phase === 'tracking' || phase === 'pending') && (origin !== nextIndex || count !== nextCount))
    )
      return interrupt(time);
    context = input.contextKey;
    if (cancelled || ended) {
      lastTime = time;
      if (phase === 'tracking') return release(cancelled ? 'cancelled' : 'phase-end', false, cancelled);
      if (phase === 'pending') {
        phase = 'locked';
        return neutral();
      }
      return neutral();
    }
    if (input.momentum === true) {
      lastTime = time;
      momentumSeen = true;
      if (phase === 'tracking') return release('momentum', true);
      phase = 'locked';
      return neutral({ preventDefault: Math.abs(dx) > Math.abs(dy) * 1.5 });
    }
    if (!dx && !dy) return feedback();
    lastTime = time;
    if (phase === 'blocked' || phase === 'vertical') return neutral();
    if (phase === 'locked')
      return neutral({ preventDefault: dx !== 0 && Math.abs(dx) >= Math.abs(dy) * 1.5 });
    if (phase === 'idle') {
      origin = nextIndex;
      count = nextCount;
      travel = width;
      phase = 'pending';
    }
    contactKnown ||= began || input.phase === 'changed' || input.momentum === false;
    phaseKnown ||= began || input.phase === 'changed';
    horizontal += Math.abs(dx);
    vertical += Math.abs(dy);
    distance += dx;
    if (phase === 'pending') {
      if (vertical >= 8 && horizontal < vertical * 1.5) {
        phase = 'vertical';
        distance = 0;
        return neutral();
      }
      if (horizontal < 8 || horizontal < vertical * 1.5)
        return neutral({ idleDelay: SPACE_GESTURE_RELEASE_MS });
      phase = 'tracking';
    }
    if (dx && lastDx && Math.sign(dx) !== Math.sign(lastDx)) {
      samples = [];
      reverseDistance = 0;
      peak = declining = 0;
    }
    reverseDistance += Math.abs(dx);
    if (dx) samples.push({ time, position: distance });
    samples = samples.filter((sample) => time - sample.time <= 80);
    const magnitude = Math.abs(dx);
    const previous = Math.abs(lastDx);
    if (magnitude >= peak) {
      peak = magnitude;
      peakTime = time;
      declining = 0;
    } else if (magnitude >= 1 && magnitude < previous * 0.95 && elapsed >= 8 && elapsed <= 45) declining++;
    else declining = 0;
    lastDx = dx || lastDx;
    const target = origin + Math.sign(distance);
    distance = clamp(
      distance,
      -travel * (target < 0 || target >= count ? 0.35 : 1.5),
      travel * (target < 0 || target >= count ? 0.35 : 1.5),
    );
    const view = feedback(true);
    // Without native phases, only a sustained, sharply diminishing same-axis
    // sequence is treated as a likely tail. Ordinary slow/stable drags stay live.
    if (
      !contactKnown &&
      declining >= 3 &&
      peak >= 12 &&
      magnitude <= peak * 0.6 &&
      time - peakTime >= 40 &&
      Math.abs(distance) >= travel * 0.18
    )
      return release('deceleration', true);
    return view;
  }

  function settle(time) {
    const elapsed = finite(time, finite(lastTime)) - lastTime;
    if (phase === 'tracking' && phaseKnown) {
      if (elapsed < 750) return { ...feedback(), idleDelay: Math.max(1, Math.ceil(750 - elapsed)) };
      return release('missing-phase-end', false, true);
    }
    if (phase === 'tracking' && elapsed >= SPACE_GESTURE_RELEASE_MS) {
      const result = release('quiet');
      return { ...result, idleDelay: Math.max(1, Math.ceil(SPACE_GESTURE_IDLE_MS - elapsed)) };
    }
    if (elapsed >= SPACE_GESTURE_IDLE_MS) {
      clear();
      return neutral();
    }
    const deadline =
      phase === 'tracking' || phase === 'pending' ? SPACE_GESTURE_RELEASE_MS : SPACE_GESTURE_IDLE_MS;
    if (phase === 'pending' && elapsed >= SPACE_GESTURE_RELEASE_MS) phase = 'locked';
    return {
      ...feedback(),
      idleDelay: Math.max(1, Math.ceil((phase === 'locked' ? SPACE_GESTURE_IDLE_MS : deadline) - elapsed)),
    };
  }
  return { update, settle, interrupt };
}
