#!/usr/bin/env node
'use strict';
const path = require('node:path');
const fs = require('node:fs/promises');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { preflight } = require('./lib/preflight.cjs');
const { prepareRuntime, fetchArtifact, assemble } = require('./lib/artifacts.cjs');
const { ensureManualProfile, toolkitRoot, configurationFor, assertContained } = require('./lib/paths.cjs');
const { sourcePlan } = require('./build/source-plan.cjs');
const COMMANDS = {
  preflight: ['root', 'platform'],
  fetch: ['root', 'engine', 'platform'],
  assemble: ['root', 'engine', 'platform', 'out'],
  launch: ['root', 'engine', 'platform', 'role', 'workspace', 'url'],
  'source-plan': ['root', 'platform'],
};
function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (!COMMANDS[command]) throw new Error('Use preflight, fetch, assemble, launch or source-plan.');
  const options = {};
  for (let index = 0; index < rest.length; index++) {
    const key = rest[index].startsWith('--') ? rest[index].slice(2) : '';
    if (!COMMANDS[command].includes(key) || Object.hasOwn(options, key))
      throw new Error(`Unknown or duplicate option: ${rest[index]}`);
    if (key === 'workspace') options.workspace = true;
    else {
      const value = rest[++index];
      if (!value || value.startsWith('--')) throw new Error(`Missing value for --${key}.`);
      options[key] = value;
    }
  }
  options.platform ||= `${process.platform}-${process.arch}`;
  if (['fetch', 'assemble', 'launch'].includes(command) && !options.engine)
    throw new Error('--engine chromium or brave is required.');
  return { command, options };
}
function validateStartURL(value = 'about:blank') {
  if (
    [
      'about:blank',
      'chrome://version',
      'chrome://version/',
      'chrome://settings/',
      'chrome://extensions/',
    ].includes(value)
  )
    return value;
  const url = new URL(value);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.search || url.hash)
    throw new Error(
      'Launcher URLs must be plain HTTP(S) addresses without credentials, queries or fragments. Navigate sign-in links manually in the browser.',
    );
  return url.href;
}
function buildManualLaunchArgs({
  profileDirectory,
  engine,
  role,
  workspace = false,
  extensionDirectory,
  url,
}) {
  configurationFor(engine, workspace);
  if (!path.isAbsolute(profileDirectory) || !['regular-a', 'regular-b', 'private'].includes(role))
    throw new Error('Invalid manual profile launch.');
  const args = [`--user-data-dir=${profileDirectory}`];
  if (role === 'private') args.push('--incognito');
  if (workspace) {
    if (!path.isAbsolute(extensionDirectory || '') || extensionDirectory.includes(','))
      throw new Error('Workspace extension path is invalid.');
    args.push(`--load-extension=${extensionDirectory}`);
  }
  args.push(validateStartURL(url));
  return args;
}
function manualEnvironment(original = process.env) {
  const env = { ...original };
  for (const key of Object.keys(env))
    if (
      /^(SSLKEYLOGFILE|CHROME_LOG_FILE|CHROME_ENABLE_LOGGING|CHROME_USER_DATA_DIR|GOOGLE_API_KEY|GOOGLE_DEFAULT_CLIENT_ID|GOOGLE_DEFAULT_CLIENT_SECRET|ELECTRON_ENABLE_LOGGING|ELECTRON_RUN_AS_NODE|NODE_OPTIONS)$/i.test(
        key,
      )
    )
      delete env[key];
  return env;
}
async function launch(options) {
  if (!['regular-a', 'regular-b', 'private'].includes(options.role))
    throw new Error('--role regular-a, regular-b or private is required.');
  configurationFor(options.engine, options.workspace);
  validateStartURL(options.url);
  const runtime = await prepareRuntime({ ...options, fetch: true });
  const profile = await ensureManualProfile(options);
  const extensionDirectory = path.join(toolkitRoot, 'extension');
  if (options.workspace) await fs.access(path.join(extensionDirectory, 'manifest.json'));
  const args = buildManualLaunchArgs({ ...options, profileDirectory: profile.directory, extensionDirectory });
  const child = spawn(runtime.executable, args, {
    detached: true,
    stdio: 'ignore',
    windowsHide: false,
    env: manualEnvironment(),
  });
  await new Promise((resolve, reject) => {
    child.once('spawn', resolve);
    child.once('error', reject);
  });
  child.unref();
  const receiptPath = await assertContained(
    runtime.root,
    path.join(runtime.root, 'launches', `${crypto.randomUUID()}.json`),
  );
  await fs.mkdir(path.dirname(receiptPath), { recursive: true });
  await fs.writeFile(
    receiptPath,
    JSON.stringify(
      {
        schemaVersion: 1,
        launchedAt: new Date().toISOString(),
        osRelease: os.release(),
        engine: options.engine,
        platform: options.platform,
        configuration: profile.configuration,
        role: options.role,
        archiveSha256: runtime.receipt.archive.sha256,
        executableSha256: runtime.receipt.files.find((file) => file.path === runtime.artifact.executable)
          ?.sha256,
        sourceRevision: runtime.artifact.sourceRevision,
        automationAttached: false,
      },
      null,
      2,
    ) + '\n',
    { flag: 'wx' },
  );
  return {
    launched: true,
    engine: options.engine,
    platform: options.platform,
    configuration: profile.configuration,
    role: options.role,
    processId: child.pid,
    profileDirectory: profile.directory,
    receiptPath,
    automationAttached: false,
    googleAcceptance: 'untested',
    notice:
      'Human-operated browser. No authentication traffic or credentials are collected by this launcher.',
  };
}
async function main(argv = process.argv.slice(2)) {
  const { command, options } = parseArgs(argv);
  if (command === 'preflight') return preflight(options);
  if (command === 'source-plan') return sourcePlan(options);
  if (command === 'fetch') {
    const result = await fetchArtifact(options);
    return { filename: result.filename, artifact: result.artifact, integrity: result.integrity };
  }
  if (command === 'assemble') return assemble(options);
  return launch(options);
}
if (require.main === module)
  main()
    .then((result) => process.stdout.write(JSON.stringify(result, null, 2) + '\n'))
    .catch((error) => {
      process.stderr.write(error.message + '\n');
      process.exitCode = 1;
    });
module.exports = { parseArgs, validateStartURL, buildManualLaunchArgs, manualEnvironment, launch, main };
