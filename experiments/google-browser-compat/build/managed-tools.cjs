'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { assertContained, assertRegularMarker } = require('../lib/paths.cjs');
const lock = require('./native-build.lock.json');

function safeBootstrapPath(filename, platform = process.platform) {
  if (
    typeof filename !== 'string' ||
    !path.isAbsolute(filename) ||
    /\s/.test(filename) ||
    (platform === 'win32' && /[&|<>^%!()"']/.test(filename))
  )
    throw new Error('Use a source path without whitespace or shell metacharacters.');
  return filename;
}

function pythonRelativeDirectory(manifest, platform = process.platform) {
  const matches = manifest
    .split(/\r?\n/)
    .filter((line) => !line.trim().startsWith('#') && /cpython3\//.test(line));
  const match = matches.length === 1 && /\s+version:([a-zA-Z0-9@._+-]+)\s*$/.exec(matches[0]);
  if (!match) throw new Error('Pinned bootstrap manifest does not identify one managed Python version.');
  const version = platform === 'win32' ? match[1].replaceAll('.', '_') : match[1];
  return `bootstrap-${version}_bin/python3/bin`;
}

function validateManagedEnvironment(env, depot) {
  const expected = {
    DEPOT_TOOLS_UPDATE: '0',
    DEPOT_TOOLS_WIN_TOOLCHAIN: '0',
    DEPOT_TOOLS_METRICS: '0',
    GIT_TERMINAL_PROMPT: '0',
    CIPD_CACHE_DIR: path.join(depot, '.zacro-cache', 'cipd'),
    VPYTHON_VIRTUALENV_ROOT: path.join(depot, '.zacro-cache', 'vpython'),
  };
  for (const [key, value] of Object.entries(expected)) {
    const aliases = Object.keys(env || {}).filter((name) => name.toLowerCase() === key.toLowerCase());
    if (aliases.length !== 1 || aliases[0] !== key || env[key] !== value)
      throw new Error('Managed tools require the sanitized, pinned native source environment.');
  }
  if (
    Object.keys(env).some((key) =>
      /^(VPYTHON_BYPASS|PYTHONHOME|PYTHONPATH|DEPOT_TOOLS_DIR|DEPOT_TOOLS_UNAME_S|DEPOT_TOOLS_BOOTSTRAP_PYTHON3|CIPD_SERVICE_URL)$/i.test(
        key,
      ),
    )
  )
    throw new Error('Managed runtime override is present in the environment.');
}

async function managedTools({ root, layout, env, execute, bootstrap = true }) {
  safeBootstrapPath(layout.depot);
  await assertContained(root, layout.depot);
  validateManagedEnvironment(env, layout.depot);
  const head = await execute('git', ['-C', layout.depot, 'rev-parse', 'HEAD'], { capture: true, env });
  if (head !== lock.depotToolsRevision)
    throw new Error('Managed tool bootstrap requires the pinned depot checkout.');
  const dirty = await execute('git', ['-C', layout.depot, 'status', '--porcelain', '--untracked-files=no'], {
    capture: true,
    env,
  });
  if (dirty) throw new Error('Managed tool source contains unreviewed edits.');
  for (const name of ['.bleeding_edge', '.cipd_client_root']) {
    try {
      await fs.lstat(path.join(layout.depot, name));
      throw new Error('Managed tool override is present; retained without execution.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  const manifestPath = path.join(layout.depot, 'bootstrap', 'manifest.txt');
  await assertContained(root, manifestPath);
  await assertRegularMarker(manifestPath);
  const expectedPythonDirectory = pythonRelativeDirectory(await fs.readFile(manifestPath, 'utf8'));
  for (const relative of [
    'bootstrap',
    '.cipd_bin',
    '.cipd_bin/.cipd/tmp',
    '.zacro-cache/cipd',
    '.zacro-cache/vpython',
    expectedPythonDirectory,
    'python3_bin_reldir.txt',
  ])
    await assertContained(root, path.join(layout.depot, relative));
  if (bootstrap) {
    if (process.platform === 'win32') {
      await execute(
        'cmd.exe',
        ['/d', '/s', '/c', safeBootstrapPath(path.join(layout.depot, 'bootstrap', 'win_tools.bat'))],
        { cwd: layout.depot, env, diskRoot: root },
      );
      await execute(
        'cmd.exe',
        ['/d', '/s', '/c', safeBootstrapPath(path.join(layout.depot, 'cipd_bin_setup.bat'))],
        { cwd: layout.depot, env, diskRoot: root },
      );
    } else {
      await execute(
        '/bin/bash',
        [
          '--noprofile',
          '--norc',
          '-c',
          'set -e; source "$1"; bootstrap_python3',
          'zacro-bootstrap',
          path.join(layout.depot, 'bootstrap_python3'),
        ],
        { cwd: layout.depot, env, diskRoot: root },
      );
      await execute(
        '/bin/bash',
        [
          '--noprofile',
          '--norc',
          '-c',
          'set -e; source "$1"; cipd_bin_setup',
          'zacro-cipd-bootstrap',
          path.join(layout.depot, 'cipd_bin_setup.sh'),
        ],
        { cwd: layout.depot, env, diskRoot: root },
      );
    }
  }
  await assertRegularMarker(path.join(layout.depot, 'python3_bin_reldir.txt'));
  const relative = (await fs.readFile(path.join(layout.depot, 'python3_bin_reldir.txt'), 'utf8')).trim();
  if (!relative || path.isAbsolute(relative) || relative.replaceAll('\\', '/') !== expectedPythonDirectory)
    throw new Error('Invalid managed Python location.');
  const python = await assertContained(
    layout.depot,
    path.join(layout.depot, relative, process.platform === 'win32' ? 'python3.exe' : 'python3'),
  );
  const vpython = await assertContained(
    layout.depot,
    path.join(layout.depot, '.cipd_bin', process.platform === 'win32' ? 'vpython3.exe' : 'vpython3'),
  );
  for (const filename of [python, vpython])
    if (!(await fs.stat(filename)).isFile()) throw new Error('Managed executables must be files.');
  const after = await execute('git', ['-C', layout.depot, 'rev-parse', 'HEAD'], { capture: true, env });
  if (after !== head) throw new Error('Managed bootstrap unexpectedly changed the depot revision.');
  if (
    await execute('git', ['-C', layout.depot, 'status', '--porcelain', '--untracked-files=no'], {
      capture: true,
      env,
    })
  )
    throw new Error('Managed bootstrap changed tracked depot sources.');
  // Match the upstream python-bin wrapper's PATH behavior. GN subprocesses and
  // Ninja actions must resolve python3 to this interpreter, especially on Mac.
  const pathKey = Object.keys(env).find((key) => key.toLowerCase() === 'path') || 'PATH';
  const additions = [
    path.dirname(python),
    ...(process.platform === 'win32' ? [path.join(path.dirname(python), 'Scripts')] : []),
  ];
  env[pathKey] = [
    ...additions,
    ...(env[pathKey] || '').split(path.delimiter).filter((entry) => entry && !additions.includes(entry)),
  ].join(path.delimiter);
  return { python, vpython };
}
module.exports = { managedTools, safeBootstrapPath, pythonRelativeDirectory, validateManagedEnvironment };
