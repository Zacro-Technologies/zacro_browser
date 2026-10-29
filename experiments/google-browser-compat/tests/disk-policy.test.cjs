'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { diskPolicy } = require('../build/disk-policy.cjs');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');

test('low-disk attempts require explicit opt-in and retain starting headroom above the reserve', () => {
  for (const env of [{}, { ZACRO_NATIVE_LOW_DISK: '0' }]) {
    assert.equal(diskPolicy(env).sourceMinimumGiB, 100);
    assert.equal(diskPolicy(env).buildMinimumGiB, 40);
  }
  const policy = diskPolicy({ ZACRO_NATIVE_LOW_DISK: '1' });
  assert.equal(policy.sourceMinimumGiB, 20);
  assert.equal(policy.buildMinimumGiB, 20);
  for (const value of ['', 'true', '15', '-1'])
    assert.throws(() => diskPolicy({ ZACRO_NATIVE_LOW_DISK: value }));
});

test('low-disk preflight still rejects missing tools and insufficient reserve headroom', async () => {
  const filename = path.resolve(__dirname, '../build/native-preflight.cjs');
  const realRequire = createRequire(filename);
  async function check(freeGiB, blockers, phase) {
    const module = { exports: {} };
    vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
      module,
      structuredClone,
      require(id) {
        if (id === './disk-policy.cjs')
          return { diskPolicy: () => diskPolicy({ ZACRO_NATIVE_LOW_DISK: '1' }) };
        if (id === '../lib/preflight.cjs')
          return {
            preflight: async () => ({
              host: 'darwin-arm64',
              freeGiB,
              requirements: { macOS: {} },
              tools: {},
              sourceBuild: {
                blockers: [
                  'Available disk is below the experiment source-checkout guard of 100 GiB.',
                  ...blockers,
                ],
                warnings: [],
              },
            }),
          };
        return realRequire(id);
      },
    });
    return module.exports.nativePreflight({ phase });
  }
  for (const phase of ['source', 'build']) {
    assert.equal((await check(20, [], phase)).sourceBuild.ready, true);
    assert.equal((await check(19.9, [], phase)).sourceBuild.ready, false);
    const report = await check(53, ['Xcode missing'], phase);
    assert.equal(report.sourceBuild.ready, false);
    assert.equal(report.sourceBuild.blockers[0], 'Xcode missing');
    assert.equal(report.diskReserveGiB, 15);
  }
});
