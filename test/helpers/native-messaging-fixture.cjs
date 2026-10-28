'use strict';

const { spawn } = require('node:child_process');

// The synthetic host is JavaScript, not a Windows executable. Use the installed
// Node runtime (or development Electron's Node mode) at the test-only launch
// boundary. The broker still verifies the registered script, reviews consent,
// passes the real origin/parent arguments and exchanges actual framed pipes.
function spawnNativeMessagingFixture(executable, args, options) {
  return spawn(process.execPath, [executable, ...args], {
    ...options,
    env: { ...process.env, ...options.env, ELECTRON_RUN_AS_NODE: '1', NODE_OPTIONS: '' },
  });
}

module.exports = { spawnNativeMessagingFixture };
