'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { emptyMatrix, validateMatrix, upgradeMatrix, recordResult, parseArguments } = require('../record.cjs');
const observation = {
  platform: 'win32-x64',
  configuration: 'chromium-engine',
  check: 'direct-google-login',
  result: 'passed',
  reason: 'completed',
};

test('Google acceptance starts untested independently for every platform and configuration', () => {
  const matrix = validateMatrix(emptyMatrix());
  assert.equal(matrix.observations.length, 90);
  assert(matrix.observations.every((item) => item.result === 'untested' && item.observedAt === null));
  const next = recordResult(matrix, { ...observation, humanObserved: true });
  assert.equal(next.observations.filter((item) => item.result === 'passed').length, 1);
  assert(matrix.observations.every((item) => item.result === 'untested'));
});

test('reaching the password field records only the preliminary check, not authenticated sign-in', () => {
  const matrix = emptyMatrix();
  const preliminary = { ...observation, check: 'google-password-step' };
  assert.throws(() => recordResult(matrix, preliminary), /human/);
  const next = recordResult(matrix, { ...preliminary, humanObserved: true });
  const passed = next.observations.filter((item) => item.result === 'passed');
  assert.equal(passed.length, 1);
  assert.equal(passed[0].check, 'google-password-step');
  assert.equal(passed[0].platform, 'win32-x64');
  assert.equal(passed[0].configuration, 'chromium-engine');
  assert(
    next.observations
      .filter((item) => item.check !== 'google-password-step')
      .every((item) => item.result === 'untested'),
  );
  assert(matrix.observations.every((item) => item.result === 'untested'));
});

test('the previous complete matrix upgrades without changing evidence or accepting malformed records', () => {
  const now = '2026-10-28T15:00:00.000Z';
  const previous = recordResult(emptyMatrix(now), { ...observation, humanObserved: true }, now);
  previous.observations = previous.observations.filter((item) => item.check !== 'google-password-step');
  assert.equal(previous.observations.length, 81);
  const before = structuredClone(previous);
  const upgraded = upgradeMatrix(previous);
  assert.equal(upgraded.observations.length, 90);
  assert.deepEqual(
    upgraded.observations.filter((item) => item.check !== 'google-password-step'),
    previous.observations,
  );
  const additions = upgraded.observations.filter((item) => item.check === 'google-password-step');
  assert.equal(additions.length, 9);
  assert(
    additions.every(
      (item) => item.result === 'untested' && item.source === 'awaiting-human' && item.observedAt === null,
    ),
  );
  assert.deepEqual(previous, before);
  for (const mutate of [
    (value) => value.observations.pop(),
    (value) => {
      value.observations[1] = { ...value.observations[0] };
    },
    (value) => {
      value.observations[0].notes = 'not-retained';
    },
    (value) => {
      value.updatedAt = '2026-10-29 (private-note)';
    },
  ]) {
    const invalid = structuredClone(previous);
    mutate(invalid);
    assert.throws(() => upgradeMatrix(invalid));
  }
});

test('fixture success cannot create a live result without an explicit human declaration', () => {
  assert.throws(() => recordResult(emptyMatrix(), observation), /human/);
  assert.throws(() =>
    recordResult(emptyMatrix(), { ...observation, humanObserved: true, reason: 'browser-rejected' }),
  );
  assert.throws(() =>
    recordResult(emptyMatrix(), { ...observation, platform: 'linux', humanObserved: true }),
  );
});

test('matrix rejects arbitrary data fields, duplicate rows and fabricated observations', () => {
  for (const mutate of [
    (m) => {
      m.email = 'not-retained';
    },
    (m) => {
      m.observations[0].notes = 'not-retained';
    },
    (m) => {
      m.observations[0].url = 'not-retained';
    },
    (m) => {
      m.observations[0].source = 'fixture';
    },
    (m) => {
      m.observations[1] = { ...m.observations[0] };
    },
  ]) {
    const matrix = emptyMatrix();
    mutate(matrix);
    assert.throws(() => validateMatrix(matrix));
  }
});

test('CLI permits enum-based human reports and rejects credential-like or repeated options', () => {
  assert.deepEqual(parseArguments(['--platform', 'win32-x64', '--human-observed']), {
    platform: 'win32-x64',
    humanObserved: true,
  });
  for (const args of [
    ['--password', 'not-retained'],
    ['--notes', 'not-retained'],
    ['--root'],
    ['--result', 'passed', '--result', 'failed'],
  ])
    assert.throws(() => parseArguments(args));
});

test('timestamps accept only real dates in canonical UTC and cannot retain arbitrary text', () => {
  const now = '2026-10-28T15:00:00.000Z';
  assert.equal(validateMatrix(emptyMatrix(now)).updatedAt, now);
  const observed = recordResult(emptyMatrix(now), { ...observation, humanObserved: true }, now);
  assert.equal(observed.observations.find((item) => item.result === 'passed').observedAt, now);
  for (const invalid of [
    '2026-10-29 (arbitrary-private-note@example.test)',
    'Thu, 29 Oct 2026 00:00:00 GMT',
    '2026-10-29T00:00:00.000+09:00',
    '2026-10-28T15:00:00Z',
    '2026-10-28T15:00:00.000Z\n',
    '2026-02-30T00:00:00.000Z',
    '2026-13-01T00:00:00.000Z',
    '2026-10-29T24:00:00.000Z',
  ]) {
    assert.throws(() => validateMatrix(emptyMatrix(invalid)));
    const matrix = structuredClone(observed);
    matrix.observations.find((item) => item.result === 'passed').observedAt = invalid;
    assert.throws(() => validateMatrix(matrix));
    assert.throws(() => recordResult(emptyMatrix(now), { ...observation, humanObserved: true }, invalid));
  }
  const template = require('../acceptance/matrix.template.json');
  assert.equal(validateMatrix(template).updatedAt, now);
});
