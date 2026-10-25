'use strict';
// Test-only preload: the inherited Node IPC channel belongs to the spawning
// parent. A per-child capability additionally authenticates its shutdown request.
// This file is never loaded by the production CLI or included in the package.
const token = process.env.ZACRO_TEST_SHUTDOWN_TOKEN;
const parent = process.env.ZACRO_TEST_SHUTDOWN_PARENT;
delete process.env.ZACRO_TEST_SHUTDOWN_TOKEN;
delete process.env.ZACRO_TEST_SHUTDOWN_PARENT;
if (!process.send || Number(parent) !== process.ppid || !/^[a-f0-9]{64}$/.test(token || ''))
  throw new Error('Test shutdown preload requires authenticated parent IPC');
const receive = (message) => {
  if (message?.type !== 'zacro-test-graceful-stop' || message.token !== token) {
    process.send({ event: 'test-shutdown-rejected' });
    return;
  }
  process.off('message', receive);
  // IPC must not keep Node alive after the real CLI handler closes its service.
  process.disconnect();
  process.emit('SIGTERM');
};
process.on('message', receive);
