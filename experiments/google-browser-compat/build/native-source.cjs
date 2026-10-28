'use strict';

// Source preparation only. Never runs a browser or opens a profile.
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const lock = require('./native-build.lock.json');
const { ensureRoot, assertContained } = require('../lib/paths.cjs');

const DEPOT_URL = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git';
const SOURCE_URL = lock.sourceRepository;

function parseOptions(argv) {
  const result = { command: argv[0] };
  if (!['prepare', 'sync', 'status'].includes(result.command))
    throw new Error('Use prepare, sync or status.');
  for (let index = 1; index < argv.length; index += 2) {
    const key = argv[index];
    if (
      !['--root', '--platform'].includes(key) ||
      !argv[index + 1] ||
      argv[index + 1].startsWith('--') ||
      result[key.slice(2)]
    )
      throw new Error('Select a root and native platform without repeated options.');
    result[key.slice(2)] = argv[index + 1];
  }
  result.platform ||= `${process.platform}-${process.arch}`;
  if (!['win32-x64', 'darwin-arm64', 'darwin-x64'].includes(result.platform))
    throw new Error('Unsupported native target.');
  return result;
}

function sourceLayout(root, platform) {
  const directory = path.join(root, 'native-source', lock.sourceVersion, platform);
  return {
    directory,
    marker: path.join(directory, '.zacro-native-source.json'),
    depot: path.join(directory, 'depot_tools'),
    checkout: path.join(directory, 'chromium'),
    src: path.join(directory, 'chromium', 'src'),
    sourceRevision: lock.sourceRevision,
    depotRevision: lock.depotToolsRevision,
  };
}

function sourceEnvironment(depot, original = process.env) {
  const env = { ...original };
  const pathKey = Object.keys(env).find((key) => key.toLowerCase() === 'path') || 'PATH';
  const originalPath = env[pathKey] || '';
  for (const key of Object.keys(env)) {
    if (
      /^(PATH|SSLKEYLOGFILE|CHROME_LOG_FILE|CHROME_ENABLE_LOGGING|GOOGLE_API_KEY|GOOGLE_DEFAULT_CLIENT_ID|GOOGLE_DEFAULT_CLIENT_SECRET|NODE_OPTIONS|ELECTRON_RUN_AS_NODE|DEPOT_TOOLS_UPDATE|DEPOT_TOOLS_WIN_TOOLCHAIN|DEPOT_TOOLS_METRICS|DEPOT_TOOLS_DIR|DEPOT_TOOLS_UNAME_S|DEPOT_TOOLS_BOOTSTRAP_PYTHON3|VPYTHON_BYPASS|VPYTHON_VIRTUALENV_ROOT|PYTHONHOME|PYTHONPATH|CHROMIUM_BUILDTOOLS_PATH|GYP_MSVS_OVERRIDE_PATH|VS2026_INSTALL|GIT_TERMINAL_PROMPT|GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_CONFIG(?:_.*)?|GCLIENT_FILE|CIPD_SERVICE_URL|CIPD_CACHE_DIR)$/i.test(
        key,
      )
    )
      delete env[key];
  }
  // On Windows environment names are case-insensitive. Remove aliases before
  // setting controlled keys so Node cannot forward an older spelling instead.
  env[pathKey] = `${depot}${path.delimiter}${originalPath}`;
  env.DEPOT_TOOLS_UPDATE = '0';
  env.DEPOT_TOOLS_WIN_TOOLCHAIN = '0';
  env.DEPOT_TOOLS_METRICS = '0';
  env.GIT_TERMINAL_PROMPT = '0';
  // Dependency clones must keep upstream bytes even when personal Git settings
  // request CRLF. These process-scoped settings never edit the global config.
  env.GIT_CONFIG_COUNT = '2';
  env.GIT_CONFIG_KEY_0 = 'core.autocrlf';
  env.GIT_CONFIG_VALUE_0 = 'false';
  env.GIT_CONFIG_KEY_1 = 'core.longpaths';
  env.GIT_CONFIG_VALUE_1 = 'true';
  env.CIPD_CACHE_DIR = path.join(depot, '.zacro-cache', 'cipd');
  env.VPYTHON_VIRTUALENV_ROOT = path.join(depot, '.zacro-cache', 'vpython');
  return env;
}

function assertNativeOperation(args, host = `${process.platform}-${process.arch}`) {
  if (args.command !== 'status' && args.platform !== host)
    throw new Error('Source preparation and sync require the selected native OS and architecture.');
}

function execute(program, args, options = {}) {
  const { capture = false, diskRoot, ...spawnOptions } = options;
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, {
      windowsHide: true,
      stdio: capture ? ['ignore', 'pipe', 'pipe'] : ['ignore', 'inherit', 'inherit'],
      ...spawnOptions,
      // A negative PID may only address this command's own process group.
      detached: process.platform !== 'win32',
    });
    let output = '';
    let settled = false;
    let childClosed = false;
    let childExited = false;
    let childCode = null;
    let childSignal = null;
    let spawnError;
    let stopReason;
    let cleanupFailure;
    let terminationDone = false;
    let reserveTimer;
    const deadlines = new Set();
    const later = (callback, milliseconds) => {
      const timer = setTimeout(() => {
        deadlines.delete(timer);
        callback();
      }, milliseconds);
      deadlines.add(timer);
      return timer;
    };
    const cleanup = () => {
      if (reserveTimer) clearInterval(reserveTimer);
      for (const timer of deadlines) clearTimeout(timer);
      deadlines.clear();
      process.removeListener('SIGINT', interrupt);
      process.removeListener('SIGTERM', terminate);
    };
    const finish = () => {
      if (settled || (stopReason ? !terminationDone : !childClosed && !spawnError)) return;
      settled = true;
      cleanup();
      if (stopReason) {
        // A broken taskkill helper or inherited pipe cannot keep this caller hung.
        child.stdout?.destroy();
        child.stderr?.destroy();
        child.unref();
        const reason =
          stopReason === 'reserve'
            ? 'Native source/build stopped to preserve the 15 GiB free-space reserve.'
            : `Native source/build interrupted by ${stopReason}.`;
        reject(
          new Error(
            `${reason} Existing files were retained.${cleanupFailure ? ` Process-tree cleanup could not be confirmed: ${cleanupFailure}.` : ''}`,
          ),
        );
      } else if (spawnError) reject(spawnError);
      else if (childCode === 0) resolve(output.trim());
      else
        reject(
          new Error(
            `${path.basename(program)} failed (${childSignal || childCode}). Existing source files were retained.`,
          ),
        );
    };
    const completeTermination = () => {
      // Allow process/pipe close events to drain, but never wait indefinitely.
      later(() => {
        terminationDone = true;
        finish();
      }, 500);
    };
    const signalGroup = (signal) => {
      try {
        process.kill(-child.pid, signal);
        return true;
      } catch (error) {
        if (error.code !== 'ESRCH') cleanupFailure = error.code || error.message;
        return error.code !== 'ESRCH';
      }
    };
    const stop = (reason) => {
      if (settled || stopReason) return;
      stopReason = reason;
      if (reserveTimer) clearInterval(reserveTimer);
      if (!Number.isInteger(child.pid) || child.pid <= 0) {
        terminationDone = true;
        finish();
        return;
      }
      if (process.platform !== 'win32') {
        if (!signalGroup('SIGTERM')) {
          completeTermination();
          return;
        }
        later(() => {
          // The leader may already have exited while clang/gclient descendants
          // ignore SIGTERM. Its still-owned group must receive the escalation.
          signalGroup('SIGKILL');
          completeTermination();
        }, 1500);
        return;
      }
      if (childExited) {
        cleanupFailure = 'the parent exited before its Windows process tree could be addressed';
        completeTermination();
        return;
      }
      let helperDone = false;
      let helperDeadline;
      const helperFinished = (error) => {
        if (helperDone) return;
        helperDone = true;
        if (helperDeadline) {
          clearTimeout(helperDeadline);
          deadlines.delete(helperDeadline);
        }
        if (error) {
          cleanupFailure = error;
          if (!childExited) child.kill('SIGKILL');
        }
        completeTermination();
      };
      const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore',
      });
      killer.once('error', (error) => helperFinished(error.code || error.message));
      killer.once('exit', (code) => helperFinished(code === 0 ? undefined : `taskkill exited ${code}`));
      helperDeadline = later(() => {
        killer.kill('SIGKILL');
        killer.unref();
        helperFinished('taskkill exceeded its five-second deadline');
      }, 5000);
    };
    const interrupt = () => stop('SIGINT');
    const terminate = () => stop('SIGTERM');
    // Keep handlers until cleanup completes so repeated signals do not abandon
    // an in-progress tree termination or start duplicate taskkill processes.
    process.on('SIGINT', interrupt);
    process.on('SIGTERM', terminate);
    let checking = false;
    if (diskRoot)
      reserveTimer = setInterval(async () => {
        if (checking || settled || stopReason) return;
        checking = true;
        try {
          const disk = await fs.statfs(diskRoot);
          if (!settled && !stopReason && disk.bavail * disk.bsize < 15 * 1024 ** 3) stop('reserve');
        } catch {
          if (!settled && !stopReason) stop('reserve');
        } finally {
          checking = false;
        }
      }, 10000);
    if (capture) {
      child.stdout.on('data', (data) => {
        if (output.length < 1024 * 1024) output += String(data).slice(0, 1024 * 1024 - output.length);
      });
      child.stderr.resume();
    }
    child.once('error', (error) => {
      spawnError = error;
      finish();
    });
    child.once('exit', (code, signal) => {
      childExited = true;
      childCode = code;
      childSignal = signal;
    });
    child.once('close', (code, signal) => {
      childClosed = true;
      childCode = code;
      childSignal = signal;
      finish();
    });
  });
}

async function owner(layout, root, platform, create) {
  await assertContained(root, layout.directory);
  const expected = {
    schemaVersion: 1,
    kind: 'zacro-native-chromium-source',
    platform,
    sourceRevision: layout.sourceRevision,
    depotRevision: layout.depotRevision,
  };
  let entries;
  try {
    entries = await fs.readdir(layout.directory);
  } catch (error) {
    if (error.code !== 'ENOENT' || !create) throw error;
    await fs.mkdir(layout.directory, { recursive: true });
    entries = [];
  }
  if (!entries.includes(path.basename(layout.marker))) {
    if (!create || entries.length) throw new Error('Refusing to adopt an existing source directory.');
    await fs.writeFile(layout.marker, JSON.stringify(expected, null, 2) + '\n', { flag: 'wx' });
  }
  const info = await fs.lstat(layout.marker);
  if (!info.isFile() || info.isSymbolicLink())
    throw new Error('Source ownership marker must be an ordinary file.');
  const actual = JSON.parse(await fs.readFile(layout.marker, 'utf8'));
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error('Source ownership or pinned revision does not match.');
  for (const location of [layout.depot, layout.checkout, layout.src]) await assertContained(root, location);
}

async function pinnedCheckout(directory, url, revision, env) {
  await fs.mkdir(directory, { recursive: true });
  const entries = await fs.readdir(directory);
  if (!entries.length) {
    await execute('git', ['init', directory], { env });
    await execute('git', ['-C', directory, 'remote', 'add', 'origin', url], { env });
    await execute('git', ['-C', directory, 'config', 'core.autocrlf', 'false'], { env });
    await execute('git', ['-C', directory, 'config', 'core.longpaths', 'true'], { env });
  }
  const origin = await execute('git', ['-C', directory, 'remote', 'get-url', 'origin'], {
    env,
    capture: true,
  });
  if (origin !== url) throw new Error('Source remote does not match the pinned upstream.');
  let head = '';
  try {
    head = await execute('git', ['-C', directory, 'rev-parse', 'HEAD'], { env, capture: true });
  } catch {}
  if (head === revision) return;
  if (head) throw new Error('Refusing to replace an existing source revision.');
  const dirty = await execute('git', ['-C', directory, 'status', '--porcelain'], { env, capture: true });
  if (dirty) throw new Error('Refusing to overwrite source changes.');
  await execute('git', ['-C', directory, 'fetch', '--depth=1', '--no-tags', 'origin', revision], {
    env,
    diskRoot: directory,
  });
  await execute('git', ['-C', directory, 'checkout', '--detach', revision], { env, diskRoot: directory });
  const actual = await execute('git', ['-C', directory, 'rev-parse', 'HEAD'], { env, capture: true });
  if (actual !== revision) throw new Error('Checked-out revision differs from the pin.');
}

function gclientConfiguration(platform) {
  const target = platform === 'win32-x64' ? 'win' : 'mac';
  return `solutions = [{\n  'name': 'src',\n  'url': '${SOURCE_URL}',\n  'managed': False,\n  'custom_deps': {},\n  'custom_vars': {},\n}]\ntarget_os = ['${target}']\n`;
}

async function main(argv) {
  const args = parseOptions(argv);
  assertNativeOperation(args);
  const root = await ensureRoot(args.root, { create: args.command !== 'status' });
  const layout = sourceLayout(root, args.platform);
  if (/\s/.test(layout.directory)) throw new Error('Chromium source path must not contain spaces.');
  await owner(layout, root, args.platform, args.command === 'prepare');
  const env = sourceEnvironment(layout.depot);
  if (args.command === 'prepare') {
    const disk = await fs.statfs(root);
    if (disk.bavail * disk.bsize < 100 * 1024 ** 3)
      throw new Error('At least 100 GiB free is required before source preparation.');
    await pinnedCheckout(layout.depot, DEPOT_URL, layout.depotRevision, env);
    await pinnedCheckout(layout.src, SOURCE_URL, layout.sourceRevision, env);
    const config = path.join(layout.checkout, '.gclient');
    await assertContained(root, config);
    const desired = gclientConfiguration(args.platform);
    try {
      if ((await fs.readFile(config, 'utf8')) !== desired)
        throw new Error('Existing gclient configuration differs; retained without replacement.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      await fs.writeFile(config, desired, { flag: 'wx' });
    }
  } else if (args.command === 'sync') {
    const { nativePreflight } = require('./native-preflight.cjs');
    const report = await nativePreflight({ root, platform: args.platform });
    if (!report.sourceBuild.ready)
      throw new Error(`Native toolchain is not ready: ${report.sourceBuild.blockers.join(' ')}`);
    const { verifySource, syncNative } = require('./native-sync.cjs');
    await verifySource({ layout, platform: args.platform, env, execute });
    const { managedTools } = require('./managed-tools.cjs');
    const tools = await managedTools({ root, layout, env, execute });
    await syncNative({ root, layout, platform: args.platform, env, execute, tools });
  }
  const sourceHead = await execute('git', ['-C', layout.src, 'rev-parse', 'HEAD'], { env, capture: true });
  const depotHead = await execute('git', ['-C', layout.depot, 'rev-parse', 'HEAD'], { env, capture: true });
  process.stdout.write(
    JSON.stringify(
      {
        platform: args.platform,
        sourceDirectory: layout.src,
        sourceHead,
        depotHead,
        sourceBuildCompleted: false,
        next:
          args.command === 'prepare'
            ? 'Resolve native preflight blockers, then sync dependencies.'
            : 'Resolve prerequisites, sync dependencies successfully, then configure and build the native prototype.',
      },
      null,
      2,
    ) + '\n',
  );
}

if (require.main === module)
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  });
module.exports = {
  parseOptions,
  sourceLayout,
  sourceEnvironment,
  assertNativeOperation,
  gclientConfiguration,
  owner,
  pinnedCheckout,
  execute,
  main,
};
