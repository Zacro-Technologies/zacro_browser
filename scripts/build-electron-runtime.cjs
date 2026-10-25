'use strict';
// Reproducible, explicit phases. Long-running phases are resumable; this script
// never resets a checkout, removes an existing build, or starts remote execution.
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createHash } = require('node:crypto');
const config = require('../runtime/electron/build.json');
const repo = path.resolve(__dirname, '..');
const patchRoot = path.join(repo, 'runtime/electron/patches');

function run(command, args, cwd, env = process.env, capture = false) {
  return new Promise((resolve, reject) => {
    // The Windows depot_tools entrypoints are batch files. All arguments here
    // are pinned literals or root paths checked by buildOptions, never JS/code.
    if (process.platform === 'win32' && command.endsWith('.bat')) {
      if ([command, ...args].some((arg) => /[&|<>^%!"\r\n]/.test(arg)))
        return reject(new Error('Unsafe Windows build argument'));
      args = ['/d', '/s', '/c', [command, ...args].join(' ')];
      command = process.env.ComSpec || 'cmd.exe';
    }
    const child = spawn(command, args, {
      cwd,
      env,
      shell: false,
      stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    let output = '';
    child.stdout?.on('data', (chunk) => {
      output += chunk;
    });
    child.once('error', reject);
    child.once('exit', (code, signal) =>
      code === 0
        ? resolve(output.trim())
        : reject(new Error(`${path.basename(command)} failed (${signal || code})`)),
    );
  });
}

function buildOptions(root, arch = process.arch) {
  if (!root || !path.isAbsolute(root) || /[\s;&|<>^%!"`$()\r\n]/.test(root))
    throw new Error('Build root must be an absolute path without spaces or shell characters');
  root = path.resolve(root);
  if (root === path.parse(root).root || root === repo || root === process.env.HOME)
    throw new Error('Use a dedicated build directory or mounted build volume');
  if (!config.targets.includes(`${process.platform}-${arch}`))
    throw new Error('Unsupported native runtime target');
  const depot = path.join(root, 'depot_tools');
  const environment = {
    ...process.env,
    PATH: `${process.env.PATH}${path.delimiter}${depot}`,
    DEPOT_TOOLS_UPDATE: '0',
    VPYTHON_VIRTUALENV_ROOT: path.join(root, 'vpython'),
    DEPOT_TOOLS_WIN_TOOLCHAIN: '0',
  };
  return {
    root,
    arch,
    depot,
    environment,
    source: path.join(root, 'src'),
    electron: path.join(root, 'src/electron'),
    out: `Zacro-${arch}`,
  };
}

async function series(directory = patchRoot) {
  const manifest = JSON.parse(await fs.readFile(path.join(directory, 'series.json'), 'utf8'));
  if (
    manifest.schemaVersion !== 1 ||
    manifest.electron?.version !== config.electronVersion ||
    manifest.electron?.commit !== config.electronCommit ||
    manifest.chromium?.version !== config.chromiumVersion ||
    !Array.isArray(manifest.patches) ||
    !manifest.patches.length
  )
    throw new Error('Patch series source identity mismatch');
  const seen = new Set();
  for (const patch of manifest.patches) {
    if (
      !/^[a-z0-9-]+\.patch$/.test(patch.file) ||
      !['electron', 'chromium'].includes(patch.target) ||
      patch.strip !== 1 ||
      seen.has(patch.file)
    )
      throw new Error('Invalid patch series entry');
    seen.add(patch.file);
    const data = await fs.readFile(path.join(directory, patch.file));
    if (createHash('sha256').update(data).digest('hex') !== patch.sha256)
      throw new Error('Patch content integrity mismatch');
  }
  return manifest;
}

async function main(phase, options) {
  const { root, arch, depot, environment: env, source, electron, out } = options;
  await fs.mkdir(root, { recursive: true });
  const suffix = process.platform === 'win32' ? '.bat' : '';
  const gclient = path.join(depot, 'gclient' + suffix);
  const git = (args, cwd = root) => run('git', args, cwd, env, true);
  const assertDepotToolsPin = async () => {
    if ((await git(['rev-parse', 'HEAD'], depot)) !== config.depotToolsCommit)
      throw new Error('Existing depot_tools differs from pinned commit; refusing to reset it');
  };
  const runPinned = async (...args) => {
    await assertDepotToolsPin();
    return run(...args);
  };
  if (phase === 'doctor') {
    const disk = await fs.statfs(root);
    console.log(
      JSON.stringify(
        {
          root,
          target: `${process.platform}-${arch}`,
          freeGiB: Math.floor((disk.bavail * disk.bsize) / 1024 ** 3),
          node: process.version,
          ...config,
        },
        null,
        2,
      ),
    );
    return;
  }
  if (phase === 'sync') {
    try {
      await fs.access(path.join(depot, '.git'));
    } catch {
      await run(
        'git',
        ['clone', '--depth', '1', 'https://chromium.googlesource.com/chromium/tools/depot_tools.git', depot],
        root,
      );
      if ((await git(['rev-parse', 'HEAD'], depot)) !== config.depotToolsCommit) {
        await git(['fetch', '--depth', '1', 'origin', config.depotToolsCommit], depot);
        await git(['checkout', '--detach', config.depotToolsCommit], depot);
      }
    }
    // Bootstrap the pinned tools without update_depot_tools moving Git to main.
    if (process.platform === 'win32') {
      await runPinned(path.join(depot, 'bootstrap/win_tools.bat'), [], depot, env);
    } else {
      await runPinned(
        'bash',
        [
          '-e',
          '-c',
          'source "$1/cipd_bin_setup.sh"; cipd_bin_setup; source "$1/bootstrap_python3"; bootstrap_python3',
          'zacro-bootstrap',
          depot,
        ],
        depot,
        env,
      );
    }
    await assertDepotToolsPin();
    const gclientFile = path.join(root, '.gclient');
    try {
      await fs.access(gclientFile);
    } catch {
      await runPinned(
        gclient,
        ['config', '--name', 'src/electron', '--unmanaged', 'https://github.com/electron/electron.git'],
        root,
        env,
      );
    }
    const gclientConfig = await fs.readFile(gclientFile, 'utf8');
    if (
      !gclientConfig.includes('src/electron') ||
      !gclientConfig.includes('https://github.com/electron/electron.git')
    )
      throw new Error('Existing gclient configuration is not an Electron checkout');
    await runPinned(
      gclient,
      [
        'sync',
        '--revision',
        `src/electron@${config.electronCommit}`,
        '--no-history',
        '--nohooks',
        '--jobs=4',
      ],
      root,
      env,
    );
    return;
  }
  // Fail before source/build writes when resuming after the tools checkout
  // changed. Each pinned execution also checks again, including within sync.
  if (['hooks', 'build', 'test', 'test-app'].includes(phase)) await assertDepotToolsPin();
  if ((await git(['rev-parse', 'HEAD'], electron)) !== config.electronCommit)
    throw new Error('Electron checkout differs from pinned source');
  await git(['merge-base', '--is-ancestor', config.chromiumCommit, 'HEAD'], source);
  if (phase === 'hooks') {
    await runPinned(gclient, ['runhooks'], root, env);
    return;
  }
  if (phase === 'patch') {
    const manifest = await series();
    for (const patch of manifest.patches) {
      const cwd = patch.target === 'electron' ? electron : source;
      const file = path.join(patchRoot, patch.file);
      let applied = false;
      try {
        await git(['apply', '--reverse', '--check', file], cwd);
        applied = true;
      } catch {
        /* First application. */
      }
      if (!applied) {
        await git(['apply', '--check', file], cwd);
        await git(['apply', file], cwd);
      }
    }
    await fs.writeFile(
      path.join(root, 'zacro-applied-series.json'),
      JSON.stringify(manifest, null, 2) + '\n',
    );
    return;
  }
  const manifest = await series();
  const applied = JSON.parse(await fs.readFile(path.join(root, 'zacro-applied-series.json'), 'utf8'));
  if (JSON.stringify(applied) !== JSON.stringify(manifest))
    throw new Error('Apply current verified patches before building');
  for (const patch of manifest.patches)
    await git(
      ['apply', '--reverse', '--check', path.join(patchRoot, patch.file)],
      patch.target === 'electron' ? electron : source,
    );
  if (phase === 'build') {
    const output = path.join(source, 'out', out);
    await fs.mkdir(output, { recursive: true });
    await fs.writeFile(
      path.join(output, 'args.gn'),
      `import("//electron/build/args/testing.gn")\ntarget_cpu = "${arch === 'x64' ? 'x64' : 'arm64'}"\noverride_electron_version = "${config.electronVersion}"\nsymbol_level = 0\nblink_symbol_level = 0\nv8_symbol_level = 0\nuse_remoteexec = false\nuse_siso = false\n`,
    );
    await runPinned(path.join(depot, 'gn' + suffix), ['gen', `out/${out}`], source, env);
    await runPinned(
      path.join(depot, 'autoninja' + suffix),
      ['-C', `out/${out}`, '-j', '4', 'electron', 'electron:electron_dist_zip'],
      source,
      env,
    );
    return;
  }
  if (phase === 'test') {
    const profileRoot = await fs.mkdtemp(path.join(root, 'zacro-native-spec-'));
    console.log(`Native spec profile root: ${profileRoot}`);
    await runPinned(
      process.execPath,
      [
        'script/spec-runner.js',
        '--runners=main',
        '--skipYarnInstall',
        '--files',
        'spec/zacro-native-capabilities.spec.ts',
        `--user-data-dir=${path.join(profileRoot, 'profile')}`,
      ],
      electron,
      {
        ...env,
        ELECTRON_OUT_DIR: out,
        // These capability specs do not print. Suppress upstream's automatic
        // printer provisioning and broad cleanup of other running instances.
        ELECTRON_TEST_PRINTER_NAME: 'zacro-capability-specs-no-printer',
        ELECTRON_SPEC_KEEP_RUNNING_INSTANCES: '1',
      },
    );
    return;
  }
  if (phase === 'test-app') {
    const executable = path.join(
      source,
      'out',
      out,
      process.platform === 'darwin' ? 'Electron.app/Contents/MacOS/Electron' : 'electron.exe',
    );
    await run(
      process.execPath,
      [
        '--test',
        '--test-concurrency=1',
        'test/e2e/extension-custom-runtime.test.cjs',
        'test/e2e/extension-font-settings.test.cjs',
      ],
      repo,
      {
        ...env,
        ZACRO_CUSTOM_ELECTRON: executable,
        ZACRO_REQUIRE_CUSTOM_ELECTRON: '1',
      },
    );
    return;
  }
  throw new Error('Unknown build phase');
}

if (require.main === module) {
  const [phase, root, arch] = process.argv.slice(2);
  if (!['doctor', 'sync', 'hooks', 'patch', 'build', 'test', 'test-app'].includes(phase)) {
    console.error(
      'Usage: node scripts/build-electron-runtime.cjs doctor|sync|hooks|patch|build|test|test-app ABSOLUTE_BUILD_ROOT [arm64|x64]',
    );
    process.exitCode = 1;
  } else
    Promise.resolve()
      .then(() => main(phase, buildOptions(root, arch)))
      .catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
      });
}
module.exports = { buildOptions, series, main };
