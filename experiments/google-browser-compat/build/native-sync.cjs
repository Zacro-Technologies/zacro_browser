'use strict';

// Dependency provenance only: this module never compiles or launches a browser.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const lock = require('./native-build.lock.json');
const branding = require('../native-branding/apply.cjs');
const { assertContained, assertRegularMarker } = require('../lib/paths.cjs');
const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
const MAX_JSON_BYTES = 16 * 1024 * 1024;
const KIND = 'zacro-native-dependency-sync';

function expectedConfiguration(platform) {
  if (!lock.platforms.includes(platform)) throw new Error('Unsupported native target.');
  const target = platform === 'win32-x64' ? 'win' : 'mac';
  return `solutions = [{\n  'name': 'src',\n  'url': '${lock.sourceRepository}',\n  'managed': False,\n  'custom_deps': {},\n  'custom_vars': {},\n}]\ntarget_os = ['${target}']\n`;
}

function validateLayout(layout, platform) {
  expectedConfiguration(platform);
  if (
    !layout ||
    !path.isAbsolute(layout.directory || '') ||
    layout.sourceRevision !== lock.sourceRevision ||
    layout.depotRevision !== lock.depotToolsRevision ||
    layout.depot !== path.join(layout.directory, 'depot_tools') ||
    layout.checkout !== path.join(layout.directory, 'chromium') ||
    layout.src !== path.join(layout.checkout, 'src') ||
    branding.manifest.revision !== lock.sourceRevision ||
    branding.manifest.files.length !== 9
  )
    throw new Error('Source layout or branding pin does not match the native build lock.');
}

function splitNames(value) {
  return value.split('\0').filter(Boolean).sort();
}

function validateSourceChanges({ staged = '', changed = '', state }) {
  if (staged) throw new Error('Staged source changes are not allowed; existing edits were retained.');
  const names = splitNames(changed);
  const reviewed = branding.manifest.files.map((file) => file.path).sort();
  if (names.some((name) => !reviewed.includes(name)))
    throw new Error('Unreviewed tracked source changes were retained without execution.');
  if (state && JSON.stringify(names) !== JSON.stringify(state === 'patched' ? reviewed : []))
    throw new Error('Tracked source changes do not match the complete reviewed branding patch.');
  return names;
}

async function verifySource({ layout, platform, env, execute, expectPatched }) {
  validateLayout(layout, platform);
  if (typeof execute !== 'function') throw new Error('A command executor is required.');
  if (expectPatched !== undefined && typeof expectPatched !== 'boolean')
    throw new Error('expectPatched must be a boolean when supplied.');
  for (const location of [layout.depot, layout.checkout, layout.src])
    await assertContained(layout.directory, location);
  const configPath = await assertContained(layout.directory, path.join(layout.checkout, '.gclient'));
  await assertRegularMarker(configPath);
  const configuration = await fs.readFile(configPath, 'utf8');
  if (configuration !== expectedConfiguration(platform))
    throw new Error('The gclient configuration differs from the reviewed native target.');
  const git = (directory, args) => execute('git', ['-C', directory, ...args], { env, capture: true });
  const sourceHead = await git(layout.src, ['rev-parse', 'HEAD']);
  const depotHead = await git(layout.depot, ['rev-parse', 'HEAD']);
  if (sourceHead !== lock.sourceRevision || depotHead !== lock.depotToolsRevision)
    throw new Error('Source or depot HEAD differs from the pinned revision.');
  for (const directory of [layout.src, layout.depot]) {
    const actualTop = await fs.realpath(await git(directory, ['rev-parse', '--show-toplevel']));
    if (actualTop !== (await fs.realpath(directory)))
      throw new Error('Native source paths must be the actual repository roots.');
  }
  if (await git(layout.depot, ['status', '--porcelain', '--untracked-files=no']))
    throw new Error('Depot contains unreviewed tracked changes; existing edits were retained.');
  const staged = await git(layout.src, ['diff', '--cached', '--name-only', '-z', '--no-ext-diff']);
  const changed = await git(layout.src, ['diff', '--name-only', '-z', '--no-ext-diff']);
  validateSourceChanges({ staged, changed });
  // File names alone are insufficient: every branding file must have one of the
  // reviewed SHA-256 values, all in the same state, and git apply must validate.
  const inspected = await branding.inspect({ source: layout.src, requireRevision: false });
  validateSourceChanges({ staged, changed, state: inspected.state });
  if (expectPatched !== undefined && (inspected.state === 'patched') !== expectPatched)
    throw new Error(`Native source must be ${expectPatched ? 'patched' : 'unpatched'} for this operation.`);
  return {
    platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: sourceHead,
    depotRevision: depotHead,
    configurationSha256: sha256(configuration),
    brandingPatchSha256: inspected.patchSha256,
    brandingState: inspected.state,
    brandingFiles: inspected.files,
    compiled: false,
  };
}

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function dependencyName(name, trailingSlash = false) {
  // gclient names CIPD/GCS entries as "checkout/path:package/or/object".
  // These identifiers are metadata, never paths used for filesystem access.
  const normalized = typeof name === 'string' && trailingSlash ? name.replace(/\/$/, '') : name;
  const location = typeof normalized === 'string' ? normalized.split(':', 1)[0] : '';
  return (
    typeof name === 'string' &&
    name.length < 4096 &&
    !/[\x00-\x1f\x7f\\]/.test(name) &&
    !normalized.endsWith(':') &&
    branding.safeRelative(location) &&
    (location === 'src' || location.startsWith('src/'))
  );
}

function validateSyncOutput(value) {
  if (!object(value) || !object(value.solutions) || !Object.keys(value.solutions).length)
    throw new Error('Invalid gclient sync output.');
  const source = value.solutions['src/'];
  if (!object(source) || source.revision !== lock.sourceRevision || source.scm !== 'git')
    throw new Error('Sync output does not identify the pinned Chromium source.');
  for (const [name, entry] of Object.entries(value.solutions)) {
    if (
      !dependencyName(name, true) ||
      !object(entry) ||
      !(entry.revision === null || typeof entry.revision === 'string') ||
      !(entry.scm === null || typeof entry.scm === 'string')
    )
      throw new Error('Invalid dependency in gclient sync output.');
  }
  return value;
}

function validateDependencyMap(value) {
  if (!object(value) || !Object.keys(value).length)
    throw new Error('Invalid actual dependency revision output.');
  for (const [name, entry] of Object.entries(value)) {
    if (
      !dependencyName(name) ||
      !object(entry) ||
      !Object.hasOwn(entry, 'url') ||
      !Object.hasOwn(entry, 'rev') ||
      ![entry.url, entry.rev].every(
        (field) => field === null || (typeof field === 'string' && field.length <= 16384),
      )
    )
      throw new Error('Invalid actual dependency revision entry.');
  }
  if (value.src?.rev !== lock.sourceRevision || value.src?.url !== lock.sourceRepository)
    throw new Error('Actual dependencies do not identify the pinned Chromium source.');
  // CIPD instance versions and GCS identifiers are not necessarily Git SHA-1s.
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((name) => [name, { url: value[name].url, rev: value[name].rev }]),
  );
}

function validateSyncAgreement(synced, dependencies) {
  for (const [name, entry] of Object.entries(synced.solutions)) {
    if (entry.scm !== 'git' || entry.revision === null) continue;
    const dependency = dependencies[name.replace(/\/$/, '')];
    if (!dependency || dependency.rev !== entry.revision)
      throw new Error('Actual Git dependencies differ from the successful sync output.');
  }
}

async function readEvidence(base, filename) {
  await assertContained(base, filename);
  await assertRegularMarker(filename);
  const stat = await fs.stat(filename);
  if (!stat.size || stat.size > MAX_JSON_BYTES) throw new Error('Dependency evidence size is invalid.');
  const bytes = await fs.readFile(filename);
  return { sha256: sha256(bytes), value: JSON.parse(bytes.toString('utf8')) };
}

async function toolsPath(layout, tools, platform) {
  const expected = path.join(
    layout.depot,
    '.cipd_bin',
    platform.startsWith('win32-') ? 'vpython3.exe' : 'vpython3',
  );
  if (tools?.vpython !== expected)
    throw new Error('Dependency commands must use the managed depot vpython executable.');
  await assertContained(layout.depot, expected);
  await assertRegularMarker(expected);
  return expected;
}

async function newEvidenceDirectory(layout) {
  const relative = `sync-evidence/${crypto.randomUUID()}`;
  const directory = await assertContained(layout.directory, path.join(layout.directory, relative));
  await fs.mkdir(path.dirname(directory), { recursive: true });
  await fs.mkdir(directory);
  return { relative, directory };
}

async function actualDependencies({ root, layout, env, execute, tools, platform, directory }) {
  const filename = path.join(directory, 'dependencies-actual.json');
  await execute(
    await toolsPath(layout, tools, platform),
    [path.join(layout.depot, 'gclient.py'), 'revinfo', '--actual', '--output-json', filename],
    { cwd: layout.checkout, env, diskRoot: root },
  );
  const result = await readEvidence(layout.directory, filename);
  return { ...result, dependencies: validateDependencyMap(result.value) };
}

async function syncNative({ root, layout, platform, env, execute, tools }) {
  await assertContained(root, layout.directory);
  const before = await verifySource({ layout, platform, env, execute });
  const vpython = await toolsPath(layout, tools, platform);
  const evidence = await newEvidenceDirectory(layout);
  const syncPath = path.join(evidence.directory, 'sync-output.json');
  await execute(
    vpython,
    [
      path.join(layout.depot, 'gclient.py'),
      'sync',
      '--nohooks',
      '--no-history',
      '--revision',
      `src@${lock.sourceRevision}`,
      '--output-json',
      syncPath,
    ],
    { cwd: layout.checkout, env, diskRoot: root },
  );
  const synced = await readEvidence(layout.directory, syncPath);
  validateSyncOutput(synced.value);
  const actual = await actualDependencies({
    root,
    layout,
    env,
    execute,
    tools,
    platform,
    directory: evidence.directory,
  });
  validateSyncAgreement(synced.value, actual.dependencies);
  const after = await verifySource({
    layout,
    platform,
    env,
    execute,
    expectPatched: before.brandingState === 'patched',
  });
  const receipt = {
    schemaVersion: 1,
    kind: KIND,
    platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    depotRevision: lock.depotToolsRevision,
    configurationSha256: after.configurationSha256,
    brandingPatchSha256: after.brandingPatchSha256,
    completedAt: new Date().toISOString(),
    syncOutput: { path: `${evidence.relative}/sync-output.json`, sha256: synced.sha256 },
    actualDependencies: { path: `${evidence.relative}/dependencies-actual.json`, sha256: actual.sha256 },
    dependencyCount: Object.keys(actual.dependencies).length,
    compiled: false,
  };
  const destination = await assertContained(layout.directory, path.join(layout.directory, 'sync.json'));
  try {
    await assertRegularMarker(destination);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const temporary = path.join(evidence.directory, 'receipt.pending.json');
  await fs.writeFile(temporary, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  await fs.rename(temporary, destination);
  return receipt;
}

function receiptMatches(receipt, proof) {
  if (
    !object(receipt) ||
    receipt.schemaVersion !== 1 ||
    receipt.kind !== KIND ||
    receipt.compiled !== false ||
    !Number.isInteger(receipt.dependencyCount) ||
    receipt.dependencyCount < 1 ||
    !Number.isFinite(Date.parse(receipt.completedAt)) ||
    [
      'platform',
      'sourceVersion',
      'sourceRevision',
      'depotRevision',
      'configurationSha256',
      'brandingPatchSha256',
    ].some((field) => receipt[field] !== proof[field])
  )
    throw new Error('Dependency sync receipt does not match the verified native source.');
  let attempt;
  for (const [key, name] of [
    ['syncOutput', 'sync-output.json'],
    ['actualDependencies', 'dependencies-actual.json'],
  ]) {
    const entry = receipt[key];
    if (!object(entry) || typeof entry.path !== 'string' || !/^[a-f0-9]{64}$/.test(entry.sha256 || ''))
      throw new Error('Invalid dependency receipt evidence.');
    const match = /^sync-evidence\/([a-f0-9-]{36})\/([^/]+)$/.exec(entry.path);
    if (!match || match[2] !== name || (attempt && attempt !== match[1]))
      throw new Error('Dependency receipt points outside its successful sync attempt.');
    attempt = match[1];
  }
  return receipt;
}

async function verifySyncReceipt({ root, layout, platform, env, execute, tools, expectPatched }) {
  await assertContained(root, layout.directory);
  const proof = await verifySource({ layout, platform, env, execute, expectPatched });
  const receipt = receiptMatches(
    (await readEvidence(layout.directory, path.join(layout.directory, 'sync.json'))).value,
    proof,
  );
  const synced = await readEvidence(layout.directory, path.join(layout.directory, receipt.syncOutput.path));
  const recorded = await readEvidence(
    layout.directory,
    path.join(layout.directory, receipt.actualDependencies.path),
  );
  if (synced.sha256 !== receipt.syncOutput.sha256 || recorded.sha256 !== receipt.actualDependencies.sha256)
    throw new Error('Successful sync evidence has changed.');
  validateSyncOutput(synced.value);
  const expected = validateDependencyMap(recorded.value);
  validateSyncAgreement(synced.value, expected);
  if (Object.keys(expected).length !== receipt.dependencyCount)
    throw new Error('Dependency count does not match the sync receipt.');
  const evidence = await newEvidenceDirectory(layout);
  const actual = await actualDependencies({
    root,
    layout,
    platform,
    env,
    execute,
    tools,
    directory: evidence.directory,
  });
  if (JSON.stringify(actual.dependencies) !== JSON.stringify(expected))
    throw new Error(
      'Actual dependency revisions changed after the successful sync; existing files were retained.',
    );
  const after = await verifySource({ layout, platform, env, execute, expectPatched });
  return {
    receipt,
    source: after,
    dependencyCount: receipt.dependencyCount,
    dependenciesVerified: true,
    compiled: false,
  };
}

module.exports = {
  expectedConfiguration,
  validateSourceChanges,
  validateSyncOutput,
  validateDependencyMap,
  validateSyncAgreement,
  receiptMatches,
  verifySource,
  syncNative,
  verifySyncReceipt,
};
