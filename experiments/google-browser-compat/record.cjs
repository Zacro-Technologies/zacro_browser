'use strict';

// Manual evidence contains only enum values and timestamps. Never accept account
// names, URLs, arbitrary notes, screenshots, request data or profile contents.
const fs = require('node:fs/promises');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const PLATFORMS = ['win32-x64', 'darwin-arm64', 'darwin-x64'];
const CONFIGURATIONS = ['brave-reference', 'chromium-engine', 'chromium-workspace'];
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
const REASONS = [
  'awaiting-human',
  'artifact-unavailable',
  'completed',
  'browser-rejected',
  'persistence-failed',
  'isolation-failed',
  'cleanup-failed',
  'flow-unavailable',
  'hardware-unavailable',
  'platform-unavailable',
  'other-failure',
];
const SCOPE = 'human-operated Google website checks; never inferred from fixtures';
const ENGINE_PINS = {
  chromium: {
    version: '159.0.8130.0',
    snapshot: '1729109',
    sourceRevision: '0c75ec0efee23f664c9a3380217ae4650bed97e6',
  },
  brave: {
    version: '1.98.60',
    sourceRevision: '52db4b25c0aa3038e9a1c6021428b136cc3cb5fc',
    chromiumVersion: '156.0.8078.48',
  },
};

function emptyMatrix(now = new Date().toISOString()) {
  return {
    schemaVersion: 1,
    updatedAt: now,
    scope: SCOPE,
    enginePins: structuredClone(ENGINE_PINS),
    observations: PLATFORMS.flatMap((platform) =>
      CONFIGURATIONS.flatMap((configuration) =>
        CHECKS.map((check) => ({
          platform,
          configuration,
          check,
          result: 'untested',
          source: 'awaiting-human',
          reason: platform === 'darwin-x64' ? 'artifact-unavailable' : 'awaiting-human',
          observedAt: null,
        })),
      ),
    ),
  };
}

function validateMatrix(value) {
  const validDate = (date) =>
    typeof date === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(date) &&
    Number.isFinite(Date.parse(date)) &&
    new Date(date).toISOString() === date;
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.keys(value).sort().join() !==
      ['enginePins', 'observations', 'schemaVersion', 'scope', 'updatedAt'].sort().join() ||
    value.schemaVersion !== 1 ||
    value.scope !== SCOPE ||
    !validDate(value.updatedAt) ||
    !isDeepStrictEqual(value.enginePins, ENGINE_PINS) ||
    !Array.isArray(value.observations) ||
    value.observations.length !== PLATFORMS.length * CONFIGURATIONS.length * CHECKS.length
  )
    throw new Error('Invalid manual matrix structure. Account data and arbitrary fields are not accepted.');
  const keys = new Set();
  for (const item of value.observations) {
    if (
      !item ||
      Object.keys(item).sort().join() !==
        ['platform', 'configuration', 'check', 'result', 'source', 'reason', 'observedAt'].sort().join() ||
      !PLATFORMS.includes(item.platform) ||
      !CONFIGURATIONS.includes(item.configuration) ||
      !CHECKS.includes(item.check) ||
      !['untested', 'passed', 'failed', 'not-applicable'].includes(item.result) ||
      !REASONS.includes(item.reason)
    )
      throw new Error(
        'Invalid manual observation. Only declared platforms, configurations and check codes are allowed.',
      );
    if (item.result === 'untested') {
      if (
        item.source !== 'awaiting-human' ||
        item.observedAt !== null ||
        !['awaiting-human', 'artifact-unavailable', 'hardware-unavailable', 'platform-unavailable'].includes(
          item.reason,
        )
      )
        throw new Error('Untested rows must not imply a human observation.');
    } else if (
      item.source !== 'human-reported' ||
      !validDate(item.observedAt) ||
      (item.result === 'passed' && item.reason !== 'completed') ||
      (item.result === 'failed' &&
        [
          'completed',
          'awaiting-human',
          'artifact-unavailable',
          'hardware-unavailable',
          'platform-unavailable',
        ].includes(item.reason)) ||
      (item.result === 'not-applicable' &&
        !['hardware-unavailable', 'flow-unavailable', 'platform-unavailable'].includes(item.reason))
    ) {
      throw new Error('Observed rows require a consistent human result, reason and timestamp.');
    }
    const key = [item.platform, item.configuration, item.check].join(':');
    if (keys.has(key)) throw new Error('Duplicate manual observation.');
    keys.add(key);
  }
  return value;
}

function upgradeMatrix(value) {
  // The previous complete matrix predates the preliminary identifier-to-password
  // check. Preserve its evidence and add only untested rows; validation still
  // rejects arbitrary fields, missing/duplicate combinations and invalid dates.
  const previousCount = PLATFORMS.length * CONFIGURATIONS.length * (CHECKS.length - 1);
  if (
    Array.isArray(value?.observations) &&
    value.observations.length === previousCount &&
    value.observations.every((item) => item?.check !== 'google-password-step')
  ) {
    return validateMatrix({
      ...value,
      observations: [
        ...value.observations,
        ...emptyMatrix(value.updatedAt).observations.filter((item) => item.check === 'google-password-step'),
      ],
    });
  }
  return validateMatrix(value);
}

function recordResult(
  matrix,
  { platform, configuration, check, result, reason, humanObserved = false },
  now = new Date().toISOString(),
) {
  const current = upgradeMatrix(matrix);
  if (!PLATFORMS.includes(platform) || !CONFIGURATIONS.includes(configuration) || !CHECKS.includes(check))
    throw new Error('Select a declared platform, configuration and check code.');
  if (!['untested', 'passed', 'failed', 'not-applicable'].includes(result) || !REASONS.includes(reason))
    throw new Error('Select a declared result and reason code.');
  if (result !== 'untested' && humanObserved !== true)
    throw new Error('A live result requires --human-observed. Fixture results are not Google acceptance.');
  const next = structuredClone(current);
  next.updatedAt = now;
  Object.assign(
    next.observations.find(
      (item) => item.platform === platform && item.configuration === configuration && item.check === check,
    ),
    {
      result,
      reason,
      source: result === 'untested' ? 'awaiting-human' : 'human-reported',
      observedAt: result === 'untested' ? null : now,
    },
  );
  return validateMatrix(next);
}

function parseArguments(argv) {
  const values = {};
  const allowed = new Set(['root', 'platform', 'configuration', 'check', 'result', 'reason']);
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === '--human-observed') {
      if (values.humanObserved) throw new Error('Duplicate option.');
      values.humanObserved = true;
    } else if (arg === '--init') {
      if (values.init) throw new Error('Duplicate option.');
      values.init = true;
    } else {
      const key = arg.startsWith('--') ? arg.slice(2) : '';
      if (
        !allowed.has(key) ||
        values[key] !== undefined ||
        !argv[index + 1] ||
        argv[index + 1].startsWith('--')
      )
        throw new Error(
          'Unknown, repeated or incomplete option. Free-text notes and credentials are not accepted.',
        );
      values[key] = argv[++index];
    }
  }
  return values;
}

async function main(argv) {
  const args = parseArguments(argv);
  const { ensureRoot, resolveRoot, assertContained } = require('./lib/paths.cjs');
  const root = await ensureRoot(resolveRoot(args.root));
  const directory = path.join(root, 'acceptance');
  await assertContained(root, directory);
  await fs.mkdir(directory, { recursive: true });
  const target = path.join(directory, 'manual-results.json');
  await assertContained(root, target);
  let matrix;
  try {
    matrix = upgradeMatrix(JSON.parse(await fs.readFile(target, 'utf8')));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    matrix = emptyMatrix();
  }
  if (!args.init) matrix = recordResult(matrix, args);
  else if (
    ['platform', 'configuration', 'check', 'result', 'reason', 'humanObserved'].some(
      (key) => args[key] !== undefined,
    )
  )
    throw new Error('--init cannot also record a result.');
  // Exclusive temporary name and rename keep an interrupted write from damaging
  // the last record. Existing observations are retained by --init.
  const temporary = `${target}.${process.pid}.tmp`;
  await assertContained(root, temporary);
  const handle = await fs.open(temporary, 'wx', 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(matrix, null, 2)}\n`, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(temporary, target);
  process.stdout.write(`Manual matrix saved: ${target}\n`);
}

if (require.main === module)
  main(process.argv.slice(2)).catch(() => {
    // Do not echo arbitrary rejected argv or input fields into terminal logs.
    process.stderr.write(
      'Manual record rejected. Use declared check/result/reason codes and the owned external root.\n',
    );
    process.exitCode = 1;
  });
module.exports = {
  PLATFORMS,
  CONFIGURATIONS,
  CHECKS,
  emptyMatrix,
  validateMatrix,
  upgradeMatrix,
  recordResult,
  parseArguments,
};
