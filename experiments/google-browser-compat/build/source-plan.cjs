'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const lock = require('../engines.lock.json');
const { resolveRoot, toolkitRoot } = require('../lib/paths.cjs');
const { preflight } = require('../lib/preflight.cjs');
async function sourcePlan({ root: input, platform = `${process.platform}-${process.arch}` } = {}) {
  if (!['win32-x64', 'darwin-arm64', 'darwin-x64'].includes(platform))
    throw new Error('Unsupported native source target.');
  const root = resolveRoot(input),
    sourceRoot = path.join(root, 'source'),
    depot = path.join(sourceRoot, 'depot_tools'),
    checkout = path.join(sourceRoot, 'chromium');
  if (/\s/.test(sourceRoot)) throw new Error('Use a source checkout path without spaces.');
  const argsFile = path.join(toolkitRoot, 'build', `args.${platform}.gn`);
  const args = await fs.readFile(argsFile, 'utf8');
  const revision = lock.engines.chromium.sourceRevision,
    windows = platform.startsWith('win32');
  const quote = (value) =>
    windows ? `"${value.replaceAll('"', '""')}"` : `'${value.replaceAll("'", "'\\''")}'`;
  return {
    schemaVersion: 1,
    executed: false,
    sourceBuildCompleted: false,
    sourceRoot,
    sourceRevision: revision,
    depotToolsRevision: lock.depotToolsRevision,
    argsFile,
    gnArgs: args,
    preflight: await preflight({ root, platform }),
    instructions: [
      'This plan does not install toolchains, clone source or run a build. Resolve native preflight blockers first.',
      'Run on the selected native operating system. Keep the existing Zacro checkout and all real browser profiles unchanged.',
      'The result keeps honest Chromium branding and the full browser implementation; it is not a Google-certified Zacro build.',
      'Do not add security-disable, certificate-bypass, automation-hiding or user-agent flags. Do not remove OS quarantine as a build step.',
      'Provision signing, update infrastructure and source/license notices separately before distribution; snapshots do not auto-update.',
    ],
    shell: windows ? 'cmd.exe (new task-local environment)' : 'sh (new task-local environment)',
    commands: [
      `${windows ? 'mkdir' : 'mkdir -p'} ${quote(sourceRoot)}`,
      `git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ${quote(depot)}`,
      `git -C ${quote(depot)} checkout --detach ${lock.depotToolsRevision}`,
      windows ? 'set DEPOT_TOOLS_UPDATE=0' : 'export DEPOT_TOOLS_UPDATE=0',
      ...(windows
        ? ['set DEPOT_TOOLS_WIN_TOOLCHAIN=0', `set "PATH=${depot};%PATH%"`]
        : [`export PATH=${quote(depot)}:"$PATH"`]),
      `${windows ? 'mkdir' : 'mkdir -p'} ${quote(checkout)}`,
      `cd ${windows ? '/d ' : ''}${quote(checkout)}`,
      'fetch --nohooks --no-history chromium',
      'cd src',
      `git fetch origin ${revision} --depth=1`,
      `git checkout --detach ${revision}`,
      `gclient sync --revision src@${revision} --with_branch_heads --with_tags`,
      `${windows ? 'mkdir out\\ZacroPrototype' : 'mkdir -p out/ZacroPrototype'}`,
      windows
        ? `copy ${quote(argsFile)} out\\ZacroPrototype\\args.gn`
        : `cp ${quote(argsFile)} out/ZacroPrototype/args.gn`,
      'gn gen out/ZacroPrototype',
      'autoninja -C out/ZacroPrototype chrome',
      'git rev-parse HEAD',
      'gclient revinfo',
      windows
        ? 'out\\ZacroPrototype\\chrome.exe --version'
        : 'out/ZacroPrototype/Chromium.app/Contents/MacOS/Chromium --version',
    ],
  };
}
module.exports = { sourcePlan };
