'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const modulePromise = import('../src/renderer/space-gesture.js');
async function fixture() {
  const { createSpaceGesture, SPACE_GESTURE_IDLE_MS, SPACE_GESTURE_RELEASE_MS } = await modulePromise;
  const gesture = createSpaceGesture();
  return {
    ...gesture,
    idle: SPACE_GESTURE_IDLE_MS,
    release: SPACE_GESTURE_RELEASE_MS,
    wheel: (time, deltaX, values = {}) =>
      gesture.update({ time, deltaX, width: 224, index: 1, count: 3, contextKey: 'regular', ...values }),
  };
}

test('a live drag keeps following beyond the former threshold and commits only when released', async () => {
  const g = await fixture();
  for (const [time, dx, distance] of [
    [0, 40, 40],
    [35, 40, 80],
    [70, 40, 120],
    [105, 40, 160],
  ]) {
    const result = g.wheel(time, dx);
    assert.equal(result.phase, 'tracking');
    assert.equal(result.commit, 0);
    assert.equal(result.offset, -distance);
    assert.equal(result.progress, distance / 224);
    assert.equal(result.preventDefault, true);
  }
  assert.equal(g.settle(105 + g.release - 1).commit, 0);
  const result = g.settle(105 + g.release);
  assert.equal(result.commit, 1);
  assert.equal(result.targetIndex, 2);
  assert.equal(result.fromOffset, -160);
  assert.equal(result.offset, -224);
  assert.equal(result.reason, 'quiet');
  assert(result.duration >= 140 && result.duration <= 240);
  assert.equal(g.settle(105 + g.idle).commit, 0);
});

test('release distance scales with sidebar width instead of a fixed pixel snap', async () => {
  const narrow = await fixture();
  const wide = await fixture();
  narrow.wheel(0, 100, { width: 200 });
  wide.wheel(0, 100, { width: 380 });
  assert.equal(narrow.settle(narrow.release).commit, 1);
  const cancelled = wide.settle(wide.release);
  assert.equal(cancelled.commit, 0);
  assert.equal(cancelled.phase, 'settling');
  assert.equal(cancelled.fromOffset, -100);
  assert.equal(cancelled.offset, 0);
});

test('a genuine short flick settles forward, while a single or slow short drag returns', async () => {
  const flick = await fixture();
  flick.wheel(0, -20);
  assert.equal(flick.wheel(20, -26).commit, 0);
  assert.equal(flick.settle(20 + flick.release).commit, -1);
  for (const slow of [true, false]) {
    const g = await fixture();
    if (slow) {
      g.wheel(0, -20);
      g.wheel(90, -26);
    } else g.wheel(90, -46);
    assert.equal(g.settle(90 + g.release).commit, 0);
  }
});

test('reversal can unwind or cancel a drag even after it passed the distance threshold', async () => {
  const g = await fixture();
  g.wheel(0, 140);
  assert.equal(g.wheel(40, -40).offset, -100);
  assert.equal(g.settle(40 + g.release).commit, 0, 'A clear movement back wins over the old position');
  const unwind = await fixture();
  unwind.wheel(0, 40);
  assert.equal(unwind.wheel(40, -30).offset, -10);
  assert.equal(unwind.wheel(80, -10).offset, 0);
  assert.equal(unwind.settle(80 + unwind.release).commit, 0);
});

test('explicit contact end settles immediately without requiring a final nonzero delta', async () => {
  const g = await fixture();
  g.wheel(0, 120, { phase: 'began' });
  assert.equal(g.settle(g.release).commit, 0, 'A known active contact waits for its explicit end');
  assert.equal(
    g.wheel(300, 10, { phase: 'changed' }).offset,
    -130,
    'A known contact can pause without losing its position',
  );
  const result = g.wheel(330, 0, { phase: 'ended' });
  assert.equal(result.commit, 1);
  assert.equal(result.reason, 'phase-end');
  assert.equal(result.fromOffset, -130);
  const cancelled = await fixture();
  cancelled.wheel(0, 160, { phase: 'began' });
  assert.equal(cancelled.wheel(30, 0, { phase: 'cancelled' }).commit, 0);
});

test('explicit momentum releases from finger position and never adds its inertial distance', async () => {
  const g = await fixture();
  g.wheel(0, 100, { momentum: false });
  const result = g.wheel(20, 500, { momentum: true });
  assert.equal(result.commit, 1);
  assert.equal(result.fromOffset, -100);
  assert.equal(result.reason, 'momentum');
  assert.equal(g.wheel(40, 500, { momentum: true, index: 2 }).commit, 0);
  assert.equal(g.wheel(500, 500, { momentum: true, index: 2 }).commit, 0);
  assert.equal(g.wheel(510, -120, { momentum: false, index: 2 }).phase, 'tracking');
  assert.equal(g.settle(510 + g.release).commit, -1);
  const short = await fixture();
  short.wheel(0, 20, { momentum: false });
  assert.equal(short.wheel(20, 500, { momentum: true }).commit, 0);
});

test('conservative deceleration recognizes a tail but explicit contact keeps the same samples live', async () => {
  for (const known of [false, true]) {
    const g = await fixture();
    let result;
    for (const [time, dx] of [
      [0, 40],
      [16, 32],
      [32, 24],
      [48, 16],
    ])
      result = g.wheel(time, dx, known ? { momentum: false } : {});
    assert.equal(result.commit, known ? 0 : 1);
    assert.equal(result.reason, known ? undefined : 'deceleration');
  }
  const stable = await fixture();
  for (let i = 0; i < 8; i++) assert.equal(stable.wheel(i * 65, 20).commit, 0);
  assert.equal(stable.settle(455 + stable.release).commit, 1);
});

test('one release stays locked through continued inertia and rearms only after quiet', async () => {
  const g = await fixture();
  g.wheel(0, 120, { index: 0 });
  assert.equal(g.settle(g.release).commit, 1);
  for (let i = 0; i < 8; i++) {
    const result = g.wheel(160 + i * 70, i % 2 ? -100 : 100);
    assert.equal(result.commit, 0);
    assert.equal(result.offset, 0);
  }
  assert.equal(g.wheel(650 + g.idle, 120).commit, 0);
  assert.equal(g.settle(650 + g.idle + g.release).commit, 1);
});

test('vertical and diagonal streams retain scrolling despite a horizontal tail', async () => {
  for (const values of [{ deltaY: 20 }, { deltaX: 20, deltaY: 20 }]) {
    const g = await fixture();
    assert.equal(g.wheel(0, 0, values).preventDefault, false);
    assert.equal(g.wheel(30, 100).preventDefault, false);
    assert.equal(g.settle(30 + g.release).commit, 0);
  }
  const g = await fixture();
  g.wheel(0, 0, { deltaY: 2 });
  assert.equal(g.wheel(10, 20, { deltaY: 1 }).phase, 'tracking');
  assert.equal(g.wheel(30, 20, { deltaY: 12 }).offset, -40);
});

test('edges resist with bounded feedback and allow deliberate reversal without wrapping', async () => {
  const g = await fixture();
  const edge = g.wheel(0, -1000, { index: 0 });
  assert.equal(edge.phase, 'edge');
  assert(edge.offset > 0 && edge.offset < 24);
  assert.equal(edge.targetIndex, null);
  assert.equal(g.settle(g.release).commit, 0);
  const reverse = await fixture();
  reverse.wheel(0, -1000, { index: 0 });
  assert.equal(reverse.wheel(60, 220, { index: 0 }).commit, 0);
  assert.equal(reverse.settle(60 + reverse.release).commit, 1);
});

test('inputs, modifiers, dragging, interruptions and context changes consume the old stream', async () => {
  for (const values of [
    { ctrlKey: true },
    { metaKey: true },
    { altKey: true },
    { buttons: 1 },
    { blocked: true },
    { defaultPrevented: true },
    { contextKey: 'private' },
    { index: 0 },
  ]) {
    const g = await fixture();
    g.wheel(0, 120);
    const blocked = g.wheel(20, 120, values);
    assert.equal(blocked.commit, 0);
    assert.equal(blocked.preventDefault, false);
    assert.equal(g.settle(20 + g.release).commit, 0);
  }
  const g = await fixture();
  g.wheel(0, 120);
  g.interrupt(20);
  assert.equal(g.settle(20 + g.release).commit, 0);
  assert.equal(g.wheel(40, 100).commit, 0);
  g.wheel(40 + g.idle, 120);
  assert.equal(g.settle(40 + g.idle + g.release).commit, 1);
});

test('line, page and shift-wheel units preserve release navigation', async () => {
  for (const [dx, values, expected] of [
    [-7, { deltaMode: 1 }, -1],
    [1, { deltaMode: 2 }, 1],
    [0, { deltaY: -100, shiftKey: true }, -1],
  ]) {
    const g = await fixture();
    assert.equal(g.wheel(0, dx, values).commit, 0);
    assert.equal(g.settle(g.release).commit, expected);
  }
});

test('zero and malformed events cannot poison feedback or extend release indefinitely', async () => {
  const g = await fixture();
  for (const dx of [NaN, Infinity, -Infinity, 0]) assert(Number.isFinite(g.wheel(0, dx).offset));
  g.wheel(10, 120);
  g.wheel(10 + g.release - 1, 0);
  assert.equal(g.settle(10 + g.release).commit, 1);
  assert.equal(g.wheel(500, 100, { index: NaN }).preventDefault, false);
});

test('one continuous contact traverses multiple Spaces and snaps only at release', async () => {
  const g = await fixture();
  g.wheel(0, 100, { index: 0, count: 6, phase: 'began' });
  assert.equal(g.settle(2000).phase, 'tracking', 'Held contacts have no arbitrary timeout');
  assert.equal(g.wheel(2100, 300, { index: 0, count: 6, phase: 'changed' }).offset, -400);
  assert.equal(g.wheel(2200, 240, { index: 0, count: 6, phase: 'changed' }).position, 640 / 224);
  const result = g.wheel(2300, 0, { index: 0, count: 6, phase: 'ended' });
  assert.equal(result.commit, 3);
  assert.equal(result.targetIndex, 3);
  assert.equal(result.offset, -672);
});

test('reversing a multi-page drag settles at the page now under the fingers', async () => {
  const g = await fixture();
  g.wheel(0, 100, { index: 0, count: 6, phase: 'began' });
  g.wheel(300, 560, { index: 0, count: 6, phase: 'changed' });
  g.wheel(380, -100, { index: 0, count: 6, phase: 'changed' });
  const result = g.wheel(420, 0, { index: 0, count: 6, phase: 'ended' });
  assert.equal(result.commit, 2);
  assert.equal(result.targetIndex, 2);
});

test('a delayed native contact phase retains wheel distance and owns the release deadline', async () => {
  const g = await fixture();
  assert.equal(g.wheel(0, 120).offset, -120);
  assert.equal(g.wheel(20, 0, { phase: 'changed' }).offset, -120);
  assert.equal(g.settle(2000).phase, 'tracking');
  assert.equal(g.wheel(2100, 0, { phase: 'ended' }).commit, 1);
});

test('quick high-distance flicks select exactly one Space and ignore the momentum tail', async () => {
  for (const direction of [-1, 1]) {
    const g = await fixture();
    g.wheel(0, direction * 150, { index: 3, count: 7, phase: 'began' });
    const drag = g.wheel(35, direction * 600, { index: 3, count: 7, phase: 'changed' });
    assert(Math.abs(drag.offset) <= 224 * 1.05);
    const result = g.wheel(55, 0, { index: 3, count: 7, phase: 'ended' });
    assert.equal(result.commit, direction);
    assert.equal(result.targetIndex, 3 + direction);
    assert.equal(g.wheel(65, direction * 900, { index: 3 + direction, count: 7, momentum: true }).commit, 0);
  }
});

test('sustained fast release snaps to distance without velocity projection', async () => {
  const g = await fixture();
  g.wheel(0, 30, { index: 0, count: 7, phase: 'began' });
  g.wheel(500, 300, { index: 0, count: 7, phase: 'changed' });
  g.wheel(520, 190, { index: 0, count: 7, phase: 'changed' });
  const result = g.wheel(525, 0, { index: 0, count: 7, phase: 'ended' });
  assert.equal(result.commit, 2, '520px reaches2.32 pages, with no projected third page');
});
