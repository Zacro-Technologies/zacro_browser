'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

test('native permission fixture reports its original setup error instead of masking it during cleanup', async () => {
  let run;
  const cleanup = [];
  const app = {
    setPath: () => {},
    whenReady: () => ({
      then: (callback) => {
        run = Promise.resolve().then(callback);
      },
    }),
    on: (_event, callback) => cleanup.push(callback),
  };
  const context = {
    process: { env: { ZACRO_CONTEXT_ROOT: '/synthetic-permission-fixture' } },
    __dirname: path.join(__dirname, 'fixtures/extensions'),
    require: (id) => {
      if (id === 'electron')
        return {
          app,
          BrowserWindow: class {
            async loadURL() {}
          },
        };
      if (id === 'node:fs/promises')
        return {
          mkdir: async () => {
            throw new Error('Original source-directory failure');
          },
        };
      return require(id);
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(context.__dirname, 'permission-host.cjs'), 'utf8'), context);
  try {
    await run;
    assert.match(context.contextResult.error, /Original source-directory failure/);
    assert.doesNotMatch(context.contextResult.error, /ReferenceError/);
  } finally {
    for (const close of cleanup) close();
  }
});
