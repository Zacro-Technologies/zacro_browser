'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { options } = require('../mechanics.cjs');

test('automated mechanics cannot accept an account URL, manual profile or arbitrary browser flags', () => {
  for (const args of [
    ['--url', 'https://accounts.google.com/'],
    ['--user-data-dir', 'existing-profile'],
    ['--role', 'regular-a'],
    ['--no-sandbox'],
    ['--engine', 'brave', '--workspace'],
    ['--engine', 'zacro-native', '--workspace'],
    ['--engine', 'chromium', '--engine', 'brave'],
  ])
    assert.throws(() => options(args));
  assert.deepEqual(options(['--engine', 'chromium', '--workspace']), { engine: 'chromium', workspace: true });
  assert.deepEqual(options(['--engine', 'zacro-native']), { engine: 'zacro-native', workspace: false });
});
