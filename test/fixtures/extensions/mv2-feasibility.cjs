'use strict';
// Focused MV2 feasibility rerun. The initial direct-preload failure is retained
// in the implementation report; the host-owned transport is now tested here.
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const result = spawnSync(
  process.execPath,
  [
    '--test',
    '--test-concurrency=1',
    '--test-name-pattern=native mv2',
    path.resolve(__dirname, '../../e2e/extension-context.test.cjs'),
  ],
  { env: { ...process.env, ZACRO_CONTEXT_MV2_PROBE: '1' }, stdio: 'inherit' },
);
process.exitCode = result.status ?? 1;
