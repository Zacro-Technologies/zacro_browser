'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { BrowserStore } = require('../src/core/store.cjs');
const { createInteractiveSite } = require('../test/fixtures/interactive-site.cjs');
const { createShowcaseState } = require('../test/fixtures/showcase-state.cjs');
const { packagedPaths } = require('./platform-build.cjs');

async function main() {
  const root = path.resolve(__dirname, '..');
  const scratch = path.join(root, '.tmp');
  await fs.mkdir(scratch, { recursive: true });
  const directory = await fs.mkdtemp(path.join(scratch, 'interactive-qa-'));
  const server = createInteractiveSite();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const packaged = process.argv.includes('--packaged');
  const showcase = process.argv.includes('--showcase');
  if (showcase) {
    const store = new BrowserStore(directory);
    store.state = createShowcaseState(url);
    store.save();
  }
  const executable = packaged ? packagedPaths(root).executable : require('electron');
  const env = { ...process.env, ZACRO_USER_DATA: directory };
  delete env.ELECTRON_RUN_AS_NODE;
  console.log(`Opening ${packaged ? 'packaged' : 'development'} Zacro with an isolated test profile.`);
  console.log(`Local test page: ${url}`);
  if (showcase) console.log('Showcase: demo Spaces, folders, and saved pages; only the local journal loads.');
  console.log('Options: --showcase for the demo workspace; --packaged for the built application.');
  console.log(
    `${process.platform === 'darwin' ? 'Quit Zacro with Command-Q' : 'Close the browser'} when finished. No real browser profile is modified.`,
  );
  const args = packaged ? [] : [root];
  if (!showcase) args.push(url);
  const child = spawn(executable, args, { cwd: root, env, windowsHide: false, stdio: 'inherit' });
  let finished = false;
  async function finish(code = 0) {
    if (finished) return;
    finished = true;
    server.closeAllConnections();
    server.close();
    // Only remove the exact temporary fixture profile created above, after
    // resolving and checking it remains inside this repository's scratch area.
    const target = path.resolve(directory);
    if (path.dirname(target) === path.resolve(scratch) && path.basename(target).startsWith('interactive-qa-'))
      await fs
        .rm(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 })
        .catch((error) => {
          console.warn(`Test profile retained at ${target}: ${error.message}`);
        });
    process.exitCode = code;
  }
  child.once('error', (error) => {
    console.error(error.message);
    void finish(1);
  });
  child.once('close', (code) => {
    void finish(code || 0);
  });
  process.once('SIGINT', () => {
    child.kill();
  });
  process.once('SIGTERM', () => {
    child.kill();
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
