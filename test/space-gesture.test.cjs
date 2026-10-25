'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const modulePromise = import('../src/renderer/space-gesture.js');
async function fixture() {
  const { createSpaceGesture, SPACE_GESTURE_IDLE_MS } = await modulePromise;
  const gesture = createSpaceGesture();
  return {
    ...gesture,
    idle: SPACE_GESTURE_IDLE_MS,
    wheel: (time, deltaX, values = {}) =>
      gesture.update({ time, deltaX, width: 224, index: 1, count: 3, contextKey: 'regular', ...values }),
  };
}

test('horizontal intent gives proportional feedback before committing one neighboring Space', async () => {
  const g = await fixture();
  const first = g.wheel(0, 20);
  assert.equal(first.phase, 'tracking');
  assert.equal(first.offset, -20);
  assert.equal(first.progress, 20 / 64);
  assert.equal(first.targetIndex, 2);
  assert.equal(first.preventDefault, true);
  assert.equal(first.commit, 0);
  const second = g.wheel(90, 20);
  assert.equal(second.offset, -40);
  assert.equal(second.commit, 0);
  const commit = g.wheel(180, 24);
  assert.equal(commit.phase, 'committed');
  assert.equal(commit.commit, 1);
  assert.equal(commit.targetIndex, 2);
  assert.equal(commit.offset, -64);
  assert.equal(g.wheel(190, 100, { index: 2 }).commit, 0);
});

test('a deliberate short flick commits without waiting for the full drag threshold', async () => {
  const g = await fixture();
  g.wheel(0, -20);
  const result = g.wheel(20, -26);
  assert.equal(result.commit, -1);
  assert.equal(result.targetIndex, 0);
  assert.equal(result.offset, 64);
  const slow = await fixture();
  slow.wheel(0, -20);
  assert.equal(slow.wheel(90, -26).commit, 0, 'A slow short movement is a preview, not a flick');
});

test('momentum tails and reversals cannot trigger a second navigation in the same stream', async () => {
  const g = await fixture();
  assert.equal(g.wheel(0, 100, { index: 0 }).commit, 1);
  for (let i = 1; i < 15; i++) {
    const result = g.wheel(i * 70, i % 2 ? 100 : -100);
    assert.equal(result.commit, 0);
    assert.equal(result.offset, 0);
  }
  assert.equal(g.wheel(980 + g.idle, 100).commit, 1, 'A separate gesture can switch again');
});

test('vertical and diagonal gestures keep scrolling even when their tails drift horizontally', async () => {
  for (const values of [{ deltaY: 20 }, { deltaX: 20, deltaY: 20 }]) {
    const g = await fixture();
    assert.equal(g.wheel(0, 0, values).preventDefault, false);
    const tail = g.wheel(30, 100);
    assert.equal(tail.preventDefault, false);
    assert.equal(tail.commit, 0);
    assert.equal(tail.phase, 'vertical');
  }
  const g = await fixture();
  assert.equal(g.wheel(0, 0, { deltaY: 2 }).commit, 0);
  assert.equal(g.wheel(10, 20, { deltaY: 1 }).phase, 'tracking', 'Tiny initial noise does not lock an axis');
});

test('horizontal direction remains stable through small vertical drift', async () => {
  const g = await fixture();
  g.wheel(0, 20, { deltaY: 2 });
  const result = g.wheel(80, 15, { deltaY: 12 });
  assert.equal(result.preventDefault, true);
  assert.equal(result.phase, 'tracking');
  assert.equal(result.offset, -35);
  assert.equal(result.direction, 1);
});

test('reversing a partial drag unwinds its displacement and can cancel without navigation', async () => {
  const g = await fixture();
  g.wheel(0, 40);
  assert.equal(g.wheel(40, -30).offset, -10);
  const cancelled = g.wheel(80, -10);
  assert.equal(cancelled.offset, 0);
  assert.equal(cancelled.commit, 0);
  assert.equal(cancelled.targetIndex, null);
  const early = g.settle(100);
  assert.equal(early.phase, 'tracking');
  assert.equal(early.idleDelay, g.idle - 20);
  assert.equal(g.settle(80 + g.idle).phase, 'idle');
});

test('an endpoint resists with a bounded rubber band and permits a deliberate reversal', async () => {
  const g = await fixture();
  const edge = g.wheel(0, -1000, { index: 0 });
  assert.equal(edge.phase, 'edge');
  assert.equal(edge.atEdge, true);
  assert.equal(edge.targetIndex, null);
  assert.equal(edge.commit, 0);
  assert(edge.offset > 0 && edge.offset < 24);
  const reversed = g.wheel(90, 160, { index: 0 });
  assert.equal(reversed.commit, 1);
  assert.equal(reversed.targetIndex, 1);
});

test('explicit momentum is ignored, while supported fresh-contact events rearm immediately', async () => {
  const g = await fixture();
  assert.equal(g.wheel(0, 100, { momentum: true }).commit, 0);
  assert.equal(g.wheel(500, 100, { momentum: true }).commit, 0, 'Long momentum gaps remain momentum');
  assert.equal(g.wheel(510, -100, { momentum: false }).commit, -1);
  assert.equal(g.wheel(530, -100, { momentum: true, index: 0 }).commit, 0);
});

test('pinch, protected controls, dragging, and previously handled events remain untouched', async () => {
  for (const blocked of [
    { ctrlKey: true },
    { metaKey: true },
    { altKey: true },
    { buttons: 1 },
    { blocked: true },
    { defaultPrevented: true },
  ]) {
    const g = await fixture();
    g.wheel(0, 20);
    const result = g.wheel(20, 100, blocked);
    assert.equal(result.preventDefault, false);
    assert.equal(result.offset, 0);
    assert.equal(result.commit, 0);
    assert.equal(g.wheel(40, 100).commit, 0, 'The blocked stream cannot resume as navigation');
    assert.equal(g.wheel(40 + g.idle, 100).commit, 1);
  }
});

test('interruption or a context change consumes remaining events without crossing profiles', async () => {
  const g = await fixture();
  g.wheel(0, 30);
  assert.equal(g.interrupt(10).offset, 0);
  assert.equal(g.wheel(30, 100).commit, 0);
  assert.equal(g.wheel(30 + g.idle, 100).commit, 1);
  const profile = await fixture();
  profile.wheel(0, 30);
  assert.equal(profile.wheel(20, 100, { contextKey: 'private' }).commit, 0);
  assert.equal(profile.wheel(260, 100, { contextKey: 'private', count: 1, index: 0 }).preventDefault, false);
  const selected = await fixture();
  selected.wheel(0, 30);
  assert.equal(selected.wheel(20, 100, { index: 0 }).commit, 0);
});

test('line, page, and shift-wheel units preserve deliberate directional navigation', async () => {
  for (const [deltaX, values, expected] of [
    [-4, { deltaMode: 1 }, -1],
    [1, { deltaMode: 2 }, 1],
    [0, { deltaY: -100, shiftKey: true }, -1],
  ]) {
    const g = await fixture();
    assert.equal(g.wheel(0, deltaX, values).commit, expected);
  }
});

test('zero or malformed wheel data cannot poison feedback or extend a gesture forever', async () => {
  const g = await fixture();
  for (const deltaX of [NaN, Infinity, -Infinity, 0]) {
    const result = g.wheel(0, deltaX);
    assert.equal(result.commit, 0);
    assert(Number.isFinite(result.offset));
  }
  g.wheel(10, 20);
  g.wheel(10 + g.idle - 1, 0);
  assert.equal(g.settle(10 + g.idle).phase, 'idle', 'Zero deltas do not prolong a stream');
  assert.equal(g.wheel(300, 100, { index: NaN }).preventDefault, false);
});
