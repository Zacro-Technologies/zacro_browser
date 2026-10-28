'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const {
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
} = require('../build/native-acceptance.cjs');
const { ensureRoot } = require('../lib/paths.cjs');

const NOW = '2026-10-28T15:00:00.000Z';
const LATER = '2026-10-28T15:01:00.000Z';
const HASH = 'a'.repeat(64);
const NEXT_HASH = 'b'.repeat(64);
const ENGINE_HASH = 'c'.repeat(64);
const NEXT_ENGINE_HASH = 'd'.repeat(64);
const ARCHIVE_HASH = 'e'.repeat(64);
const OTHER_ARCHIVE_HASH = 'f'.repeat(64);
const digestInventory = (files) => createHash('sha256').update(JSON.stringify(files)).digest('hex');
const RUNTIME_HASH = receipt().runtimeSha256;
const NEXT_RUNTIME_HASH = receipt('win32-x64', HASH, NEXT_ENGINE_HASH).runtimeSha256;
const passed = {
  platform: 'win32-x64',
  check: 'google-password-step',
  result: 'passed',
  reason: 'completed',
  humanObserved: true,
};

function receipt(platform = 'win32-x64', executableSha256 = HASH, engineSha256 = ENGINE_HASH) {
  const mac = platform.startsWith('darwin');
  const files = mac
    ? [
        { path: 'Zacro Prototype.app', type: 'directory', mode: 0o755 },
        { path: 'Zacro Prototype.app/Contents', type: 'directory', mode: 0o755 },
        { path: 'Zacro Prototype.app/Contents/Frameworks', type: 'directory', mode: 0o755 },
        {
          path: 'Zacro Prototype.app/Contents/Frameworks/engine.dylib',
          type: 'file',
          mode: 0o755,
          sha256: engineSha256,
        },
        { path: 'Zacro Prototype.app/Contents/MacOS', type: 'directory', mode: 0o755 },
        {
          path: 'Zacro Prototype.app/Contents/MacOS/Zacro Prototype',
          type: 'file',
          mode: 0o755,
          sha256: executableSha256,
        },
      ]
    : [
        { path: 'chrome.dll', sha256: engineSha256 },
        { path: 'chrome.exe', sha256: executableSha256 },
      ];
  return {
    schemaVersion: 1,
    ...sourcePins(),
    platform,
    executableSha256,
    runtimeSha256: digestInventory(files),
    files,
    compiled: true,
  };
}

function verifiedImport(build = receipt(), archive = ARCHIVE_HASH) {
  return {
    directory: 'private-import-directory',
    executable: 'private-executable-path',
    buildReceipt: build,
    imported: {
      schemaVersion: 1,
      kind: 'zacro-imported-native-artifact',
      ...sourcePins(),
      platform: build.platform,
      artifactId: archive,
      archiveSha256: archive,
      runtimeSha256: build.runtimeSha256,
      executableSha256: build.executableSha256,
      locallyCompiled: false,
      sourceBuildReported: true,
      googleAcceptance: 'untested',
      ciRunUrl: 'https://github.com/fixture/repository/actions/runs/123',
      ciProvenance: 'operator-supplied; unsigned receipts do not authenticate the CI origin',
    },
  };
}

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-native-acceptance-test-'));
  t.after(async () => {
    const real = await fs.realpath(directory);
    const parent = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), parent.toLowerCase());
    assert.match(path.basename(real), /^zacro-native-acceptance-test-/u);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}

async function writeReceipt(root, data = receipt()) {
  const filename = path.join(root, 'native-builds', sourcePins().sourceVersion, data.platform, 'build.json');
  await fs.mkdir(path.dirname(filename), { recursive: true });
  await fs.writeFile(filename, JSON.stringify(data));
  return filename;
}

function recordArgs(root, check = 'google-password-step') {
  return [
    '--root',
    root,
    '--platform',
    'win32-x64',
    '--check',
    check,
    '--result',
    'passed',
    '--reason',
    'completed',
    '--human-observed',
  ];
}

test('native template is independent of snapshot evidence and contains all 30 untested checks', async () => {
  await verifyBrandingPatch();
  const template = emptyMatrix(null, NOW);
  assert.equal(template.artifact, null);
  assert.equal(template.observations.length, 30);
  assert.equal(template.sourcePins.sourceVersion, '156.0.8078.48');
  assert.notEqual(
    template.sourcePins.sourceRevision,
    require('../engines.lock.json').engines.chromium.sourceRevision,
  );
  assert.equal(
    template.sourcePins.brandingPatchSha256,
    require('../native-branding/manifest.json').patch.sha256,
  );
  for (const platform of PLATFORMS) {
    assert.deepEqual(
      template.observations.filter((item) => item.platform === platform).map((item) => item.check),
      CHECKS,
    );
  }
  assert.ok(template.observations.every((item) => item.result === 'untested' && item.observedAt === null));
  assert.throws(() => recordResult(template, receipt(), passed, LATER), /another runtime/u);
  const forged = structuredClone(template);
  Object.assign(forged.observations[0], {
    result: 'passed',
    source: 'human-reported',
    reason: 'completed',
    observedAt: NOW,
  });
  assert.throws(() => validateMatrix(forged), /bound to this runtime/u);
});

test('only matching compiled receipts yield a safe artifact identity for each native platform', () => {
  for (const platform of PLATFORMS) {
    assert.deepEqual(
      artifactFromReceipt({ ...receipt(platform), privateBuildMetadata: 'do-not-copy' }, platform),
      {
        platform,
        executableSha256: HASH,
        runtimeSha256: receipt(platform).runtimeSha256,
      },
    );
  }
  for (const change of [
    { compiled: false },
    { compiled: 'true' },
    { schemaVersion: 2 },
    { productName: 'Chromium' },
    { sourceVersion: '159.0.8130.0' },
    { sourceRevision: '0'.repeat(40) },
    { brandingPatchSha256: '0'.repeat(64) },
    { platform: 'darwin-arm64' },
    { executableSha256: 'not-a-hash' },
    { runtimeSha256: undefined },
    { runtimeSha256: 'not-a-hash' },
  ])
    assert.throws(() => artifactFromReceipt({ ...receipt(), ...change }, 'win32-x64'));
  assert.throws(() => artifactFromReceipt(null, 'win32-x64'));
  assert.throws(() => artifactFromReceipt(receipt(), 'linux-x64'));
});

test('human password-step reports cannot imply full sign-in or another platform result', () => {
  const build = receipt();
  const before = emptyMatrix(artifactFromReceipt(build, build.platform), NOW);
  for (const result of ['passed', 'failed', 'not-applicable']) {
    const reason =
      result === 'passed' ? 'completed' : result === 'failed' ? 'browser-rejected' : 'hardware-unavailable';
    assert.throws(
      () => recordResult(before, build, { ...passed, result, reason, humanObserved: false }, LATER),
      /human-observed/u,
    );
  }
  const next = recordResult(before, build, passed, LATER);
  assert.equal(next.observations.filter((item) => item.result === 'passed').length, 1);
  assert.equal(
    next.observations.find((item) => item.platform === 'win32-x64' && item.check === 'direct-google-login')
      .result,
    'untested',
  );
  assert.equal(before.observations[0].result, 'untested');
  assert.throws(
    () => recordResult(next, receipt('darwin-arm64'), { ...passed, platform: 'darwin-arm64' }, LATER),
    /another runtime/u,
  );
  assert.throws(() => recordResult(next, receipt('win32-x64', NEXT_HASH), passed, LATER), /another runtime/u);
  assert.throws(
    () => recordResult(next, receipt('win32-x64', HASH, NEXT_ENGINE_HASH), passed, LATER),
    /another runtime/u,
  );
  assert.throws(() => recordResult(next, build, { ...passed, reason: 'browser-rejected' }, LATER), /reason/u);
});

test('compiled acceptance identity must match the complete inventory and launcher hash', () => {
  for (const change of [
    (value) => {
      delete value.files;
    },
    (value) => {
      value.files = [];
    },
    (value) => {
      value.files[0].sha256 = NEXT_ENGINE_HASH;
    },
    (value) => {
      value.executableSha256 = NEXT_HASH;
    },
    (value) => {
      value.files.reverse();
      value.runtimeSha256 = digestInventory(value.files);
    },
    (value) => {
      value.files[0].path = '../engine.dll';
      value.runtimeSha256 = digestInventory(value.files);
    },
    (value) => {
      value.files.push({ ...value.files[1] });
      value.runtimeSha256 = digestInventory(value.files);
    },
  ]) {
    const invalid = receipt();
    change(invalid);
    assert.throws(() => artifactFromReceipt(invalid, 'win32-x64'));
  }
  const mac = receipt('darwin-arm64');
  const previous = mac.runtimeSha256;
  mac.files[0].mode = 0o700;
  assert.throws(() => artifactFromReceipt(mac, 'darwin-arm64'), /runtime hash/u);
  mac.runtimeSha256 = digestInventory(mac.files);
  assert.notEqual(artifactFromReceipt(mac, 'darwin-arm64').runtimeSha256, previous);
});

test('matrix validation rejects private data, duplicate combinations, invalid dates and inconsistent evidence', () => {
  const build = receipt();
  const base = recordResult(
    emptyMatrix(artifactFromReceipt(build, build.platform), NOW),
    build,
    passed,
    LATER,
  );
  const changes = [
    (value) => {
      value.notes = 'private-note';
    },
    (value) => {
      value.artifact.account = 'private-note';
    },
    (value) => {
      value.observations[0].notes = 'private-note';
    },
    (value) => {
      value.observations[1] = { ...value.observations[0] };
    },
    (value) => {
      value.observations.pop();
    },
    (value) => {
      value.observations[0].source = 'fixture';
    },
    (value) => {
      value.observations[0].observedAt = '2026-10-28T15:02:00.000Z';
    },
    (value) => {
      value.observations[0].platform = 'darwin-arm64';
    },
    (value) => {
      value.observations[1].observedAt = NOW;
    },
    (value) => {
      value.observations[0].result = 'not-applicable';
      value.observations[0].reason = 'completed';
    },
    (value) => {
      value.observations[0].result = 'failed';
      value.observations[0].reason = 'hardware-unavailable';
    },
    (value) => {
      value.sourcePins.sourceRevision = '0'.repeat(40);
    },
  ];
  for (const change of changes) {
    const modified = structuredClone(base);
    change(modified);
    assert.throws(() => validateMatrix(modified));
  }
  for (const date of [
    'private-note',
    '2026-02-30T15:00:00.000Z',
    '2026-10-28',
    '2026-10-28T15:00:00Z',
    '2026-10-28T15:00:00.000+00:00',
  ]) {
    assert.throws(() => emptyMatrix(null, date));
    const modified = structuredClone(base);
    modified.observations[0].observedAt = date;
    assert.throws(() => validateMatrix(modified));
  }
});

test('CLI accepts only enum observations and never echoes rejected account-like input', () => {
  assert.deepEqual(parseArguments(['--init']), { init: true });
  assert.equal(parseArguments(['--init', '--platform', 'darwin-x64']).platform, 'darwin-x64');
  for (const args of [
    [],
    ['--email', 'private-input-marker'],
    ['--notes', 'private-input-marker'],
    ['--init', '--platform', 'linux-x64'],
    ['--init', '--human-observed'],
    ['--init', '--check', 'gmail'],
    ['--init', '--init'],
    ['--help', '--root', 'x'],
    ['--init', '--root'],
    ['--init', '--root', 'a', '--root', 'b'],
    ['--platform', 'win32-x64', '--check', 'gmail', '--result', 'passed', '--reason', 'completed'],
  ])
    assert.throws(() => parseArguments(args));
  const child = spawnSync(
    process.execPath,
    [path.resolve(__dirname, '../build/native-acceptance.cjs'), '--notes', 'private-input-marker'],
    { encoding: 'utf8' },
  );
  assert.equal(child.status, 1);
  assert.doesNotMatch(`${child.stdout}${child.stderr}`, /private-input-marker/u);
  assert.match(child.stderr, /Native record rejected/u);
});

test('external template needs no build; observed reports require one and preserve earlier evidence', async (t) => {
  const temporary = await scratch(t);
  const root = path.join(temporary, 'owned');
  const template = await main(['--root', root, '--init']);
  assert.equal(path.dirname(template.target), path.join(root, 'acceptance'));
  assert.equal(path.basename(template.target), reportBasename());
  const templateBytes = await fs.readFile(template.target, 'utf8');
  const legacy = path.join(root, 'acceptance', 'manual-results.json');
  await fs.writeFile(legacy, 'unrelated-snapshot-and-brave-evidence');
  await assert.rejects(main(recordArgs(root)), { code: 'ENOENT' });
  await writeReceipt(root, { ...receipt(), compiled: false });
  await assert.rejects(main(recordArgs(root)), /compiled/u);
  await writeReceipt(root);
  const first = await main(recordArgs(root));
  assert.equal(first.matrix.artifact.executableSha256, HASH);
  assert.equal(first.matrix.artifact.runtimeSha256, RUNTIME_HASH);
  assert.equal(first.matrix.observations.filter((item) => item.result === 'passed').length, 1);
  assert.ok(first.target.endsWith(`-win32-x64-${RUNTIME_HASH}.json`));
  const firstBytes = await fs.readFile(first.target, 'utf8');
  const unchanged = await main(['--root', root, '--platform', 'win32-x64', '--init']);
  assert.equal(unchanged.target, first.target);
  assert.equal(await fs.readFile(first.target, 'utf8'), firstBytes);
  // Component DLLs/resources changed while the chrome.exe launcher did not.
  // The complete runtime hash must select a fresh matrix in this case.
  await writeReceipt(root, receipt('win32-x64', HASH, NEXT_ENGINE_HASH));
  const rebuilt = await main(['--root', root, '--platform', 'win32-x64', '--init']);
  assert.notEqual(rebuilt.target, first.target);
  assert.equal(rebuilt.matrix.artifact.executableSha256, first.matrix.artifact.executableSha256);
  assert.equal(rebuilt.matrix.artifact.runtimeSha256, NEXT_RUNTIME_HASH);
  assert.ok(rebuilt.matrix.observations.every((item) => item.result === 'untested'));
  assert.equal(await fs.readFile(first.target, 'utf8'), firstBytes);
  assert.equal(await fs.readFile(template.target, 'utf8'), templateBytes);
  assert.equal(await fs.readFile(legacy, 'utf8'), 'unrelated-snapshot-and-brave-evidence');
  assert.ok(
    (await fs.readdir(path.join(root, 'acceptance'))).every(
      (name) => !name.endsWith('.tmp') && !name.endsWith('.lock'),
    ),
  );
});

test('owned-root checks reject receipt/output links outside the root and refuse foreign roots', async (t) => {
  const temporary = await scratch(t);
  const foreign = path.join(temporary, 'foreign');
  await fs.mkdir(foreign);
  await fs.writeFile(path.join(foreign, 'keep.txt'), 'keep');
  await assert.rejects(main(['--root', foreign, '--init']), /adopt/u);
  const root = await ensureRoot(path.join(temporary, 'owned'));
  const destination = path.join(root, 'native-builds');
  await fs.symlink(foreign, destination, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(main(recordArgs(root)), /outside/u);
  const other = await ensureRoot(path.join(temporary, 'other-owned'));
  await fs.symlink(
    foreign,
    path.join(other, 'acceptance'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(main(['--root', other, '--init']), /outside/u);
  assert.equal(await fs.readFile(path.join(foreign, 'keep.txt'), 'utf8'), 'keep');
  assert.deepEqual(await fs.readdir(foreign), ['keep.txt']);
});

test('an exclusive record lock prevents overwriting another writer or its existing report', async (t) => {
  const temporary = await scratch(t);
  const root = await ensureRoot(path.join(temporary, 'owned'));
  await writeReceipt(root);
  const initial = await main(['--root', root, '--init', '--platform', 'win32-x64']);
  const before = await fs.readFile(initial.target, 'utf8');
  await fs.writeFile(`${initial.target}.lock`, 'other-run');
  await assert.rejects(main(recordArgs(root)), { code: 'EEXIST' });
  assert.equal(await fs.readFile(initial.target, 'utf8'), before);
  assert.equal(await fs.readFile(`${initial.target}.lock`, 'utf8'), 'other-run');
});

test('imported acceptance records hash identity without local compilation or private import metadata', () => {
  for (const platform of PLATFORMS) {
    const verified = verifiedImport(receipt(platform));
    const artifact = artifactFromImport(verified, platform, ARCHIVE_HASH);
    assert.deepEqual(artifact, {
      platform,
      executableSha256: HASH,
      runtimeSha256: verified.buildReceipt.runtimeSha256,
      importedArtifactSha256: ARCHIVE_HASH,
      locallyCompiled: false,
    });
    const template = emptyMatrix(artifact, NOW);
    const selection = { ...passed, platform, artifact: ARCHIVE_HASH };
    const result = recordImportedResult(template, verified, selection, LATER);
    assert.equal(result.observations.filter((row) => row.result === 'passed').length, 1);
    assert.equal(
      result.observations.find((row) => row.platform === platform && row.check === 'direct-google-login')
        .result,
      'untested',
    );
    assert.doesNotMatch(
      JSON.stringify(result),
      /private-import|private-executable|ciRunUrl|fixture\/repository|sourceBuildReported/u,
    );
    assert.notEqual(
      reportBasename(artifact),
      reportBasename(artifactFromReceipt(verified.buildReceipt, platform)),
    );
    assert.ok(reportBasename(artifact).includes(artifact.runtimeSha256));
    assert.ok(reportBasename(artifact).endsWith(`-${ARCHIVE_HASH}.json`));
    assert.throws(
      () => recordImportedResult(template, verified, { ...selection, humanObserved: false }, LATER),
      /human-observed/u,
    );
    assert.throws(() => recordResult(template, verified.buildReceipt, selection, LATER), /another runtime/u);
    const local = emptyMatrix(artifactFromReceipt(verified.buildReceipt, platform), NOW);
    assert.throws(() => recordImportedResult(local, verified, selection, LATER), /another runtime/u);
    const other = verifiedImport(verified.buildReceipt, OTHER_ARCHIVE_HASH);
    assert.throws(
      () => recordImportedResult(template, other, { ...selection, artifact: OTHER_ARCHIVE_HASH }, LATER),
      /another runtime/u,
    );
  }
});

test('import acceptance rejects unbuilt, mismatched or falsely local provenance', () => {
  for (const update of [
    (value) => {
      value.buildReceipt.compiled = false;
    },
    (value) => {
      value.imported.locallyCompiled = true;
    },
    (value) => {
      value.imported.sourceBuildReported = false;
    },
    (value) => {
      value.imported.googleAcceptance = 'passed';
    },
    (value) => {
      value.imported.artifactId = OTHER_ARCHIVE_HASH;
    },
    (value) => {
      value.imported.archiveSha256 = OTHER_ARCHIVE_HASH;
    },
    (value) => {
      value.imported.runtimeSha256 = '0'.repeat(64);
    },
    (value) => {
      value.imported.executableSha256 = NEXT_HASH;
    },
    (value) => {
      value.imported.sourceRevision = '0'.repeat(40);
    },
    (value) => {
      value.imported.platform = 'darwin-arm64';
    },
  ]) {
    const invalid = verifiedImport();
    update(invalid);
    assert.throws(() => artifactFromImport(invalid, 'win32-x64', ARCHIVE_HASH));
  }
  const artifact = artifactFromImport(verifiedImport(), 'win32-x64', ARCHIVE_HASH);
  assert.throws(() => emptyMatrix({ ...artifact, locallyCompiled: true }, NOW));
  assert.throws(() => emptyMatrix({ ...artifact, ciRunUrl: 'private-input' }, NOW));
  assert.throws(() => artifactFromImport(verifiedImport(), 'win32-x64', OTHER_ARCHIVE_HASH));
});

test('artifact CLI requires full hash and platform while preserving existing source-build options', () => {
  assert.equal(
    parseArguments(['--init', '--platform', 'win32-x64', '--artifact', ARCHIVE_HASH]).artifact,
    ARCHIVE_HASH,
  );
  assert.equal(
    parseArguments([...recordArgs('fixture-root'), '--artifact', ARCHIVE_HASH]).artifact,
    ARCHIVE_HASH,
  );
  for (const values of [
    ['--init', '--artifact', ARCHIVE_HASH],
    ['--init', '--platform', 'win32-x64', '--artifact', ARCHIVE_HASH.slice(0, 12)],
    ['--init', '--platform', 'win32-x64', '--artifact', 'private-input'],
    ['--init', '--platform', 'win32-x64', '--artifact', ARCHIVE_HASH.toUpperCase()],
    ['--init', '--platform', 'win32-x64', '--artifact', ARCHIVE_HASH, '--artifact', OTHER_ARCHIVE_HASH],
  ])
    assert.throws(() => parseArguments(values));
  assert.deepEqual(parseArguments(['--init']), { init: true });
});

test('artifact CLI calls read-only verification for each observation and never creates or falls back to a local build', async (t) => {
  const temporary = await scratch(t);
  const root = await ensureRoot(path.join(temporary, 'owned'));
  const importer = require('../build/native-artifact.cjs');
  const calls = [];
  let available = true;
  t.mock.method(importer, 'verifyImported', async (args) => {
    calls.push(args);
    if (!available) throw new Error('Imported runtime verification failed.');
    return verifiedImport();
  });
  const init = ['--root', root, '--init', '--platform', 'win32-x64', '--artifact', ARCHIVE_HASH];
  const initial = await main(init);
  assert.ok(initial.matrix.observations.every((row) => row.result === 'untested'));
  assert.equal(initial.matrix.artifact.locallyCompiled, false);
  const recorded = await main([...recordArgs(root), '--artifact', ARCHIVE_HASH]);
  assert.equal(recorded.target, initial.target);
  assert.equal(recorded.matrix.observations.filter((row) => row.result === 'passed').length, 1);
  assert.deepEqual(calls, [
    { root, artifact: ARCHIVE_HASH },
    { root, artifact: ARCHIVE_HASH },
  ]);
  await assert.rejects(fs.access(path.join(root, 'native-builds')), { code: 'ENOENT' });
  const before = await fs.readFile(recorded.target, 'utf8');
  // A valid local receipt must not rescue a missing/tampered selected import.
  await writeReceipt(root);
  const local = await main(['--root', root, '--init', '--platform', 'win32-x64']);
  assert.notEqual(local.target, recorded.target);
  available = false;
  await assert.rejects(
    main([...recordArgs(root, 'gmail'), '--artifact', ARCHIVE_HASH]),
    /verification failed/u,
  );
  assert.equal(await fs.readFile(recorded.target, 'utf8'), before);
  assert.ok(
    (await main(['--root', root, '--init', '--platform', 'win32-x64'])).matrix.observations.every(
      (row) => row.result === 'untested',
    ),
  );
  assert.equal(calls.length, 3);
});
