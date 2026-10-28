'use strict';

// Human observations only. This recorder neither runs a browser nor reads its
// profiles. A compiled-build receipt gates recording; it is not Google evidence.
// Each complete runtime hash gets a separate report. Component DLLs/resources
// can change while the launcher executable stays identical.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const lock = require('./native-build.lock.json');
const branding = require('../native-branding/manifest.json');
const { ensureRoot, assertContained, assertRegularMarker } = require('../lib/paths.cjs');

const PLATFORMS = ['win32-x64', 'darwin-arm64', 'darwin-x64'];
const CHECKS = [
  'google-password-step',
  'direct-google-login',
  'gmail',
  'drive',
  'restart-persistence',
  'sign-out',
  'regular-profile-isolation',
  'private-session-cleanup',
  'platform-passkey',
  'security-key',
];
const RESULTS = ['untested', 'passed', 'failed', 'not-applicable'];
const UNTESTED_REASONS = [
  'awaiting-human',
  'artifact-unavailable',
  'hardware-unavailable',
  'platform-unavailable',
];
const FAILURE_REASONS = [
  'browser-rejected',
  'persistence-failed',
  'isolation-failed',
  'cleanup-failed',
  'flow-unavailable',
  'other-failure',
];
const NA_REASONS = ['hardware-unavailable', 'flow-unavailable', 'platform-unavailable'];
const SCOPE = 'human-operated native Zacro website checks; never inferred from compilation or fixtures';
const SHA256 = /^[a-f0-9]{64}$/u;
const HELP = `Native Zacro acceptance (no browser or account automation)
  --init [--root ABSOLUTE_PATH]
    Create an unbuilt template: all three platforms remain untested.
  --init --platform PLATFORM [--root ABSOLUTE_PATH]
    Initialize a report for the matching compiled runtime receipt.
  --platform PLATFORM --check CHECK --result RESULT --reason REASON
    --human-observed [--root ABSOLUTE_PATH]
    Record only a check a human actually performed on that complete runtime.
  Add --artifact SHA to either platform command to use an already imported
    artifact. Its complete runtime is verified without a local source build.
    Imported evidence is separate and explicitly records locallyCompiled:false.

Platforms: ${PLATFORMS.join(', ')}
Checks: ${CHECKS.join(', ')}
Results: ${RESULTS.join(', ')}
Reasons: ${[...new Set([...UNTESTED_REASONS, ...FAILURE_REASONS, ...NA_REASONS, 'completed'])].join(', ')}

The password step means only that entering the identifier reached a password
field. It does not establish sign-in, Gmail, Drive or persistence acceptance.
Observed results require a matching compiled native build receipt or a verified
imported compiled runtime. Unsigned import receipts do not authenticate CI origin.
Receipts identify artifacts, not successful authentication. New runtime hashes start
untested. Templates need no receipt and cannot contain observed results.
No emails, URLs, account identifiers, credentials or free-text notes are accepted.
`;

function exactKeys(value, keys) {
  return (
    value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join() === [...keys].sort().join()
  );
}

function canonicalDate(value) {
  return (
    typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(value) &&
    Number.isFinite(Date.parse(value)) &&
    new Date(value).toISOString() === value
  );
}

function sourcePins() {
  if (
    lock.schemaVersion !== 1 ||
    lock.productName !== 'Zacro Prototype' ||
    !/^\d+\.\d+\.\d+\.\d+$/u.test(lock.sourceVersion) ||
    !/^[a-f0-9]{40}$/u.test(lock.sourceRevision) ||
    !isDeepStrictEqual(lock.platforms, PLATFORMS) ||
    branding.schemaVersion !== 1 ||
    branding.product !== lock.productName ||
    branding.version !== lock.sourceVersion ||
    branding.revision !== lock.sourceRevision ||
    !SHA256.test(branding.patch?.sha256)
  )
    throw new Error('Native source and branding pins do not match.');
  return {
    productName: lock.productName,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: branding.patch.sha256,
  };
}

async function verifyBrandingPatch() {
  const directory = path.resolve(__dirname, '../native-branding');
  const filename = path.resolve(directory, branding.patch.path);
  const relative = path.relative(directory, filename);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Invalid branding patch path.');
  await assertRegularMarker(filename);
  const digest = createHash('sha256')
    .update(await fs.readFile(filename))
    .digest('hex');
  if (digest !== sourcePins().brandingPatchSha256) throw new Error('Branding patch does not match its pin.');
}

function validateArtifact(artifact) {
  const imported =
    artifact !== null && typeof artifact === 'object' && Object.hasOwn(artifact, 'importedArtifactSha256');
  const keys = ['platform', 'executableSha256', 'runtimeSha256'];
  if (imported) keys.push('importedArtifactSha256', 'locallyCompiled');
  if (
    !exactKeys(artifact, keys) ||
    !PLATFORMS.includes(artifact.platform) ||
    typeof artifact.executableSha256 !== 'string' ||
    !SHA256.test(artifact.executableSha256) ||
    typeof artifact.runtimeSha256 !== 'string' ||
    !SHA256.test(artifact.runtimeSha256) ||
    (imported &&
      (typeof artifact.importedArtifactSha256 !== 'string' ||
        !SHA256.test(artifact.importedArtifactSha256) ||
        artifact.locallyCompiled !== false))
  )
    throw new Error('Invalid native runtime identity.');
  return artifact;
}

function artifactFromImport(verified, platform, requestedSha256) {
  const artifact = artifactFromReceipt(verified?.buildReceipt, platform);
  const imported = verified?.imported;
  if (
    typeof requestedSha256 !== 'string' ||
    !SHA256.test(requestedSha256) ||
    !imported ||
    imported.schemaVersion !== 1 ||
    imported.kind !== 'zacro-imported-native-artifact' ||
    imported.artifactId !== requestedSha256 ||
    imported.archiveSha256 !== requestedSha256 ||
    imported.locallyCompiled !== false ||
    imported.sourceBuildReported !== true ||
    imported.googleAcceptance !== 'untested' ||
    imported.platform !== platform ||
    imported.runtimeSha256 !== artifact.runtimeSha256 ||
    imported.executableSha256 !== artifact.executableSha256 ||
    Object.entries(sourcePins()).some(([key, value]) => imported[key] !== value)
  )
    throw new Error('Verified import does not identify the selected compiled native runtime.');
  return validateArtifact({ ...artifact, importedArtifactSha256: requestedSha256, locallyCompiled: false });
}

function artifactFromReceipt(receipt, platform) {
  const pins = sourcePins();
  if (
    !receipt ||
    typeof receipt !== 'object' ||
    Array.isArray(receipt) ||
    receipt.schemaVersion !== 1 ||
    receipt.compiled !== true ||
    !PLATFORMS.includes(platform) ||
    receipt.platform !== platform ||
    Object.entries(pins).some(([key, value]) => receipt[key] !== value)
  )
    throw new Error('A matching compiled native build receipt is required.');
  const artifact = validateArtifact({
    platform,
    executableSha256: receipt.executableSha256,
    runtimeSha256: receipt.runtimeSha256,
  });
  // A copied/stale hash field alone is not enough: bind it to the actual build
  // receipt's complete canonical inventory, including Mac modes and links.
  if (!Array.isArray(receipt.files) || !receipt.files.length || receipt.files.length > 30000)
    throw new Error('Native build receipt must contain its complete runtime inventory.');
  let previous = '';
  for (const item of receipt.files) {
    const mac = platform.startsWith('darwin');
    const kind = mac ? item?.type : 'file';
    const fields = mac ? ['path', 'type', 'mode'] : ['path'];
    if (kind === 'file') fields.push('sha256');
    else if (kind === 'symlink') fields.push('link');
    else if (kind !== 'directory') throw new Error('Invalid native runtime inventory entry.');
    if (
      !exactKeys(item, fields) ||
      typeof item.path !== 'string' ||
      item.path <= previous ||
      /[\0\\]/u.test(item.path) ||
      item.path.split('/').some((part) => !part || part === '.' || part === '..') ||
      (mac && item.path !== 'Zacro Prototype.app' && !item.path.startsWith('Zacro Prototype.app/')) ||
      (mac && (!Number.isInteger(item.mode) || item.mode < 0 || item.mode > 0o7777)) ||
      (kind === 'file' && (typeof item.sha256 !== 'string' || !SHA256.test(item.sha256))) ||
      (kind === 'symlink' &&
        (typeof item.link !== 'string' ||
          !item.link ||
          /[\0\\]/u.test(item.link) ||
          path.win32.isAbsolute(item.link) ||
          path.posix.isAbsolute(item.link)))
    )
      throw new Error('Invalid or noncanonical native runtime inventory.');
    previous = item.path;
  }
  if (
    createHash('sha256').update(JSON.stringify(receipt.files)).digest('hex') !== artifact.runtimeSha256 ||
    !receipt.files.some(
      (item) => item.path === branding.outputs[platform] && item.sha256 === artifact.executableSha256,
    )
  )
    throw new Error('Native executable or runtime hash differs from the build inventory.');
  // Build receipts may contain build paths or diagnostics. Project only these
  // safe identity fields; never copy or log arbitrary receipt metadata.
  return artifact;
}

function emptyMatrix(artifact = null, now = new Date().toISOString()) {
  if (artifact !== null) validateArtifact(artifact);
  return validateMatrix({
    schemaVersion: 1,
    updatedAt: now,
    scope: SCOPE,
    sourcePins: sourcePins(),
    artifact: artifact === null ? null : { ...artifact },
    observations: PLATFORMS.flatMap((platform) =>
      CHECKS.map((check) => ({
        platform,
        check,
        result: 'untested',
        source: 'awaiting-human',
        reason: artifact?.platform === platform ? 'awaiting-human' : 'artifact-unavailable',
        observedAt: null,
      })),
    ),
  });
}

function validateMatrix(matrix) {
  if (
    !exactKeys(matrix, ['schemaVersion', 'updatedAt', 'scope', 'sourcePins', 'artifact', 'observations']) ||
    matrix.schemaVersion !== 1 ||
    matrix.scope !== SCOPE ||
    !canonicalDate(matrix.updatedAt) ||
    !isDeepStrictEqual(matrix.sourcePins, sourcePins()) ||
    !Array.isArray(matrix.observations) ||
    matrix.observations.length !== PLATFORMS.length * CHECKS.length
  )
    throw new Error('Invalid native matrix. Account data and arbitrary fields are not accepted.');
  if (matrix.artifact !== null) validateArtifact(matrix.artifact);
  const seen = new Set();
  for (const item of matrix.observations) {
    if (
      !exactKeys(item, ['platform', 'check', 'result', 'source', 'reason', 'observedAt']) ||
      !PLATFORMS.includes(item.platform) ||
      !CHECKS.includes(item.check) ||
      !RESULTS.includes(item.result)
    )
      throw new Error('Invalid native observation codes.');
    if (item.result === 'untested') {
      if (
        item.source !== 'awaiting-human' ||
        item.observedAt !== null ||
        !UNTESTED_REASONS.includes(item.reason)
      )
        throw new Error('Untested rows cannot imply an observation.');
    } else if (
      matrix.artifact?.platform !== item.platform ||
      item.source !== 'human-reported' ||
      !canonicalDate(item.observedAt) ||
      item.observedAt > matrix.updatedAt ||
      (item.result === 'passed' && item.reason !== 'completed') ||
      (item.result === 'failed' && !FAILURE_REASONS.includes(item.reason)) ||
      (item.result === 'not-applicable' && !NA_REASONS.includes(item.reason))
    ) {
      throw new Error('Observed results require a consistent human report bound to this runtime.');
    }
    const key = `${item.platform}:${item.check}`;
    if (seen.has(key)) throw new Error('Duplicate native observation.');
    seen.add(key);
  }
  return matrix;
}

function validateSelection({ platform, check, result, reason, humanObserved = false }) {
  if (!PLATFORMS.includes(platform) || !CHECKS.includes(check) || !RESULTS.includes(result))
    throw new Error('Select a declared native platform, check and result.');
  const allowed =
    result === 'untested'
      ? UNTESTED_REASONS
      : result === 'passed'
        ? ['completed']
        : result === 'failed'
          ? FAILURE_REASONS
          : NA_REASONS;
  if (!allowed.includes(reason)) throw new Error('Select a reason consistent with the result.');
  if (result !== 'untested' && humanObserved !== true)
    throw new Error('Observed results require --human-observed. Compilation does not prove acceptance.');
}

function recordResult(matrix, receipt, selection, now = new Date().toISOString()) {
  return applyObservation(matrix, artifactFromReceipt(receipt, selection.platform), selection, now);
}

function recordImportedResult(matrix, verified, selection, now = new Date().toISOString()) {
  return applyObservation(
    matrix,
    artifactFromImport(verified, selection.platform, selection.artifact),
    selection,
    now,
  );
}

function applyObservation(matrix, artifact, selection, now) {
  validateMatrix(matrix);
  validateSelection(selection);
  if (!isDeepStrictEqual(matrix.artifact, artifact))
    throw new Error('This report belongs to another runtime. Initialize the new artifact separately.');
  const next = structuredClone(matrix);
  next.updatedAt = now;
  Object.assign(
    next.observations.find((item) => item.platform === selection.platform && item.check === selection.check),
    {
      result: selection.result,
      reason: selection.reason,
      source: selection.result === 'untested' ? 'awaiting-human' : 'human-reported',
      observedAt: selection.result === 'untested' ? null : now,
    },
  );
  return validateMatrix(next);
}

function reportBasename(artifact = null) {
  if (artifact !== null) validateArtifact(artifact);
  const pins = sourcePins();
  const imported = artifact?.importedArtifactSha256;
  const base = `native${imported ? '-import' : ''}-${pins.sourceVersion}-${pins.brandingPatchSha256.slice(0, 12)}`;
  return `${base}${artifact ? `-${artifact.platform}-${artifact.runtimeSha256}` : ''}${imported ? `-${imported}` : ''}.json`;
}

function parseArguments(argv) {
  const result = {};
  const values = new Set(['root', 'platform', 'artifact', 'check', 'result', 'reason']);
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    const key = arg.startsWith('--') ? arg.slice(2) : '';
    if (['init', 'human-observed', 'help'].includes(key)) {
      const name = key === 'human-observed' ? 'humanObserved' : key;
      if (result[name] !== undefined) throw new Error('Duplicate native acceptance option.');
      result[name] = true;
    } else if (
      values.has(key) &&
      result[key] === undefined &&
      argv[index + 1] &&
      !argv[index + 1].startsWith('--')
    ) {
      result[key] = argv[++index];
    } else
      throw new Error('Unknown or incomplete option. Account data and free-text notes are not accepted.');
  }
  if (
    result.artifact !== undefined &&
    (!SHA256.test(result.artifact) || !PLATFORMS.includes(result.platform))
  )
    throw new Error('--artifact requires a complete lowercase SHA-256 and a declared platform.');
  if (result.help) {
    if (Object.keys(result).length !== 1) throw new Error('--help must be used alone.');
  } else if (result.init) {
    if (
      ['check', 'result', 'reason', 'humanObserved'].some((key) => result[key] !== undefined) ||
      (result.platform !== undefined && !PLATFORMS.includes(result.platform))
    )
      throw new Error('--init cannot record an observation.');
  } else validateSelection(result);
  return result;
}

async function readSmallJSON(root, filename, limit = 1024 * 1024) {
  await assertContained(root, filename);
  await assertRegularMarker(filename);
  if ((await fs.stat(filename)).size > limit) throw new Error('Unexpected native record size.');
  return JSON.parse(await fs.readFile(filename, 'utf8'));
}

async function main(argv) {
  const args = parseArguments(argv);
  if (args.help) return { help: HELP };
  await verifyBrandingPatch();
  const root = await ensureRoot(args.root);
  let receipt = null;
  let artifact = null;
  let verifiedImport = null;
  if (args.artifact !== undefined) {
    // This API rechecks the imported payload, receipts and full runtime inventory.
    // It does not compile, launch or synthesize a local source-build receipt.
    verifiedImport = await require('./native-artifact.cjs').verifyImported({ root, artifact: args.artifact });
    artifact = artifactFromImport(verifiedImport, args.platform, args.artifact);
  } else if (args.platform !== undefined) {
    receipt = await readSmallJSON(
      root,
      path.join(root, 'native-builds', sourcePins().sourceVersion, args.platform, 'build.json'),
      16 * 1024 * 1024,
    );
    artifact = artifactFromReceipt(receipt, args.platform);
  }
  const directory = await assertContained(root, path.join(root, 'acceptance'));
  await fs.mkdir(directory, { recursive: true });
  const target = await assertContained(root, path.join(directory, reportBasename(artifact)));
  // A short-lived exclusive lock prevents concurrent reports from silently
  // overwriting one another. A stale lock fails closed; never remove another run's lock.
  const lockPath = await assertContained(root, `${target}.lock`);
  const handle = await fs.open(lockPath, 'wx', 0o600);
  let temporary;
  try {
    let matrix;
    let existing = false;
    try {
      matrix = validateMatrix(await readSmallJSON(root, target));
      if (!isDeepStrictEqual(matrix.artifact, artifact)) throw new Error('Native artifact identity differs.');
      existing = true;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      matrix = emptyMatrix(artifact);
    }
    if (!args.init)
      matrix = verifiedImport
        ? recordImportedResult(matrix, verifiedImport, args)
        : recordResult(matrix, receipt, args);
    if (!args.init || !existing) {
      temporary = await assertContained(root, `${target}.${randomUUID()}.tmp`);
      const output = await fs.open(temporary, 'wx', 0o600);
      try {
        await output.writeFile(`${JSON.stringify(matrix, null, 2)}\n`);
        await output.sync();
      } finally {
        await output.close();
      }
      await fs.rename(temporary, target);
      temporary = undefined;
    }
    return { target, matrix };
  } finally {
    if (temporary) await fs.unlink(temporary).catch(() => {});
    await handle.close();
    await fs.unlink(lockPath);
  }
}

if (require.main === module)
  main(process.argv.slice(2))
    .then((result) =>
      process.stdout.write(result.help || `Native acceptance saved: ${path.basename(result.target)}\n`),
    )
    .catch(() => {
      // Never echo rejected argv, receipt metadata or parser diagnostics.
      process.stderr.write(
        'Native record rejected. Use --help, declared codes, an owned external root and a matching compiled receipt.\n',
      );
      process.exitCode = 1;
    });

module.exports = {
  PLATFORMS,
  CHECKS,
  sourcePins,
  verifyBrandingPatch,
  artifactFromReceipt,
  artifactFromImport,
  emptyMatrix,
  validateMatrix,
  recordResult,
  recordImportedResult,
  reportBasename,
  parseArguments,
  main,
};
