'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {
  ensureRoot,
  resolveRoot,
  ensureManualProfile,
  assertContained,
  repositoryRoot,
  toolkitRoot,
  ROOT_MARKER,
  PROFILE_MARKER,
  inside,
} = require('../lib/paths.cjs');
const {
  getArtifactManifest,
  validateArtifactURL,
  verifyArchive,
  fetchArtifact,
  writeStoredZip,
  inspectZip,
  safeArchiveName,
  treeIntegrity,
  kitStartInstructions,
} = require('../lib/artifacts.cjs');
const { parseArgs, buildManualLaunchArgs, validateStartURL, manualEnvironment } = require('../cli.cjs');
const { versionAtLeast } = require('../lib/preflight.cjs');

async function scratch(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-tooling-test-'));
  t.after(async () => {
    // Only remove the unique test directory created by this invocation.
    const real = await fs.realpath(directory);
    const temporary = await fs.realpath(os.tmpdir());
    assert.equal(path.dirname(real).toLowerCase(), temporary.toLowerCase());
    assert.match(path.basename(real), /^zacro-tooling-test-/);
    await fs.rm(real, { recursive: true });
  });
  return directory;
}
function fixtureArtifact(bytes) {
  return {
    ...getArtifactManifest('chromium', 'win32-x64'),
    size: bytes.length,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    md5Base64: crypto.createHash('md5').update(bytes).digest('base64'),
  };
}
async function fixtureZip(filename, entries) {
  await writeStoredZip(
    filename,
    entries.map((entry) => ({ name: entry.name, data: entry.link || entry.data || '' })),
  );
  const links = new Set(entries.filter((entry) => entry.link).map((entry) => entry.name));
  if (!links.size) return;
  const data = await fs.readFile(filename),
    end = data.length - 22;
  let offset = data.readUInt32LE(end + 16);
  for (let index = 0; index < entries.length; index++) {
    const length = data.readUInt16LE(offset + 28),
      extra = data.readUInt16LE(offset + 30),
      comment = data.readUInt16LE(offset + 32);
    const name = data.subarray(offset + 46, offset + 46 + length).toString();
    if (links.has(name)) data.writeUInt32LE((0o120777 << 16) >>> 0, offset + 38);
    offset += 46 + length + extra + comment;
  }
  await fs.writeFile(filename, data);
}

test('owned roots cannot overlap the repository or adopt foreign data', async (t) => {
  const temporary = await scratch(t),
    root = path.join(temporary, 'owned');
  assert.equal(await ensureRoot(root), root);
  assert.equal(await ensureRoot(root), root);
  assert.equal(
    JSON.parse(await fs.readFile(path.join(root, ROOT_MARKER))).kind,
    'zacro-google-browser-compat',
  );
  assert.throws(() => resolveRoot('.'), /absolute/);
  assert.throws(() => resolveRoot(os.homedir()), /home/);
  assert.throws(() => resolveRoot(path.parse(root).root), /volume/);
  if (repositoryRoot) {
    assert.throws(() => resolveRoot(repositoryRoot), /outside/);
    assert.throws(() => resolveRoot(path.join(repositoryRoot, 'dist', 'prototype')), /outside/);
    assert.throws(() => resolveRoot(path.dirname(repositoryRoot)), /outside/);
  }
  const foreign = path.join(temporary, 'foreign');
  await fs.mkdir(foreign);
  await fs.writeFile(path.join(foreign, 'keep.txt'), 'user data');
  await assert.rejects(ensureRoot(foreign), /Refusing to adopt/);
  assert.equal(await fs.readFile(path.join(foreign, 'keep.txt'), 'utf8'), 'user data');
  const marker = path.join(root, ROOT_MARKER);
  await fs.writeFile(marker, JSON.stringify({ schemaVersion: 1, kind: 'foreign', root }));
  await assert.rejects(ensureRoot(root), /does not match/);
});

test('manual roles, engines and workspace configurations always use distinct profiles', async (t) => {
  const root = await scratch(t),
    directories = new Set();
  for (const engine of ['chromium', 'brave'])
    for (const workspace of engine === 'chromium' ? [false, true] : [false])
      for (const role of ['regular-a', 'regular-b', 'private']) {
        const options = { root, engine, platform: 'win32-x64', workspace, role };
        const result = await ensureManualProfile(options);
        assert.equal(directories.has(result.directory), false);
        directories.add(result.directory);
        assert.equal((await ensureManualProfile(options)).directory, result.directory);
        const owner = JSON.parse(await fs.readFile(result.marker));
        assert.equal(owner.purpose, 'manual-acceptance');
        assert.equal(
          owner.configuration,
          engine === 'brave' ? 'reference' : workspace ? 'workspace' : 'engine-only',
        );
      }
  assert.equal(directories.size, 9);
  await assert.rejects(
    ensureManualProfile({ root, engine: 'brave', platform: 'win32-x64', role: 'regular-a', workspace: true }),
    /unmodified/,
  );
  await assert.rejects(
    ensureManualProfile({ root, engine: 'chromium', platform: '../escape', role: 'regular-a' }),
    /Unsupported/,
  );
  await assert.rejects(
    ensureManualProfile({ root, engine: 'chromium', platform: 'win32-x64', role: '../escape' }),
    /Select/,
  );
});

test('existing unowned profiles and mismatched purpose markers are preserved and refused', async (t) => {
  const root = await scratch(t);
  await ensureRoot(root);
  const directory = path.join(root, 'profiles', 'chromium', 'win32-x64', 'engine-only', 'regular-a');
  await fs.mkdir(directory, { recursive: true });
  await fs.writeFile(path.join(directory, 'Preferences'), 'do not adopt');
  const options = { root, engine: 'chromium', platform: 'win32-x64', role: 'regular-a' };
  await assert.rejects(ensureManualProfile(options), /pre-existing/);
  await fs.writeFile(
    path.join(directory, PROFILE_MARKER),
    JSON.stringify({
      schemaVersion: 1,
      kind: 'zacro-google-browser-compat',
      purpose: 'automated-fixture',
      engine: 'chromium',
      platform: 'win32-x64',
      configuration: 'engine-only',
      role: 'regular-a',
    }),
  );
  await assert.rejects(ensureManualProfile(options), /another experiment/);
  assert.equal(await fs.readFile(path.join(directory, 'Preferences'), 'utf8'), 'do not adopt');
});

test('containment rejects lexical traversal and real junction escapes', async (t) => {
  const temporary = await scratch(t),
    root = path.join(temporary, 'root'),
    outside = path.join(temporary, 'outside');
  await ensureRoot(root);
  await fs.mkdir(outside);
  await assert.rejects(assertContained(root, path.join(root, '..', 'outside')), /escapes/);
  assert.equal(inside(root, root + '-other'), false);
  const redirect = path.join(root, 'redirect');
  await fs.symlink(outside, redirect, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(assertContained(root, path.join(redirect, 'new-profile')), /redirects/);
  if (repositoryRoot) {
    const repoLink = path.join(temporary, 'repo-link');
    await fs.symlink(repositoryRoot, repoLink, process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(ensureRoot(path.join(repoLink, 'do-not-create')), /overlaps/);
  }
});

test('manual launch exposes a closed argument allowlist and no credential logging environment', () => {
  const profileDirectory = path.join(os.tmpdir(), 'manual-profile'),
    extensionDirectory = path.join(os.tmpdir(), 'workspace');
  assert.deepEqual(buildManualLaunchArgs({ profileDirectory, engine: 'chromium', role: 'regular-a' }), [
    `--user-data-dir=${profileDirectory}`,
    'about:blank',
  ]);
  assert.deepEqual(
    buildManualLaunchArgs({
      profileDirectory,
      engine: 'chromium',
      role: 'private',
      workspace: true,
      extensionDirectory,
    }),
    [
      `--user-data-dir=${profileDirectory}`,
      '--incognito',
      `--load-extension=${extensionDirectory}`,
      'about:blank',
    ],
  );
  assert.throws(
    () =>
      buildManualLaunchArgs({
        profileDirectory,
        engine: 'brave',
        role: 'regular-a',
        workspace: true,
        extensionDirectory,
      }),
    /unmodified/,
  );
  for (const flag of [
    'remote-debugging-port',
    'enable-automation',
    'user-agent',
    'no-sandbox',
    'disable-web-security',
    'ignore-certificate-errors',
    'args',
  ])
    assert.throws(() => parseArgs(['launch', '--engine', 'chromium', `--${flag}`, '1']), /Unknown/);
  assert.throws(() => parseArgs(['launch', '--engine', 'chromium', '--engine', 'brave']), /duplicate/);
  assert.throws(() => parseArgs(['launch', '--engine']), /Missing/);
  assert.equal(parseArgs(['launch', '--engine', 'chromium', '--workspace']).options.workspace, true);
  const sensitive = [
    'SSLKEYLOGFILE',
    'CHROME_LOG_FILE',
    'CHROME_ENABLE_LOGGING',
    'GOOGLE_API_KEY',
    'GOOGLE_DEFAULT_CLIENT_ID',
    'GOOGLE_DEFAULT_CLIENT_SECRET',
    'NODE_OPTIONS',
    'ELECTRON_RUN_AS_NODE',
  ];
  const original = Object.fromEntries(sensitive.map((name) => [name, 'never-print-this-value']));
  original.PATH = 'normal';
  original.sslkeylogfile = 'also-remove';
  assert.deepEqual(manualEnvironment(original), { PATH: 'normal' });
  assert.equal(original.GOOGLE_API_KEY, 'never-print-this-value');
});

test('manual navigation defaults to blank and refuses secret-bearing or local-file arguments', () => {
  assert.equal(validateStartURL(), 'about:blank');
  assert.equal(validateStartURL('https://accounts.google.com'), 'https://accounts.google.com/');
  assert.equal(validateStartURL('chrome://version'), 'chrome://version');
  for (const url of [
    'file:///C:/Users/secret',
    'javascript:alert(1)',
    'https://user:password@example.com',
    'https://example.com/?code=secret',
    'https://example.com/#token',
    'chrome://crash',
  ])
    assert.throws(() => validateStartURL(url));
});

test('all upstream artifact pins have strong hashes and generation-bound Chromium identities', () => {
  for (const engine of ['chromium', 'brave'])
    for (const platform of ['win32-x64', 'darwin-arm64']) {
      const artifact = getArtifactManifest(engine, platform);
      validateArtifactURL(artifact);
      assert.match(artifact.sha256, /^[a-f0-9]{64}$/);
      if (engine === 'chromium') {
        assert.equal(new URL(artifact.url).searchParams.get('generation'), artifact.generation);
        assert.match(artifact.sha256Provenance, /not a publisher-provided/);
      }
    }
  assert.throws(() => getArtifactManifest('chromium', 'darwin-x64'), /No pinned artifact/);
  const artifact = getArtifactManifest('chromium', 'win32-x64');
  assert.throws(
    () => validateArtifactURL({ ...artifact, url: 'https://example.com/chrome.zip' }),
    /Unrecognized/,
  );
  assert.throws(() => validateArtifactURL({ ...artifact, generation: '1' }), /generation/);
  assert.throws(() => validateArtifactURL({ ...artifact, size: 3 * 1024 ** 3 }), /size/);
});

test('archive verification rejects modified bytes, digest mismatch and truncation without replacing files', async (t) => {
  const directory = await scratch(t),
    filename = path.join(directory, 'fixture.zip');
  const bytes = Buffer.from('verified fixture'),
    artifact = fixtureArtifact(bytes);
  await fs.writeFile(filename, bytes);
  assert.equal((await verifyArchive(filename, artifact)).sha256, artifact.sha256);
  await assert.rejects(
    verifyArchive(filename, { ...artifact, sha256: '0'.repeat(64) }),
    /integrity mismatch/,
  );
  await assert.rejects(
    verifyArchive(filename, { ...artifact, md5Base64: 'A'.repeat(22) + '==' }),
    /integrity mismatch/,
  );
  await fs.writeFile(filename, 'modified fixture');
  await assert.rejects(verifyArchive(filename, artifact), /integrity mismatch/);
  assert.equal(await fs.readFile(filename, 'utf8'), 'modified fixture');
});

test('fetch refuses a missing cache without network and refuses a corrupt cache', async (t) => {
  const root = await scratch(t);
  // The shipped kit has one real payload, so choose a different engine when
  // necessary instead of mistaking a successful offline bootstrap for failure.
  const chromiumPayload = path.join(
    toolkitRoot,
    'payload',
    getArtifactManifest('chromium', 'win32-x64').cacheName,
  );
  const bundledChromium = await fs.access(chromiumPayload).then(
    () => true,
    () => false,
  );
  const engine = bundledChromium ? 'brave' : 'chromium';
  const options = { root, engine, platform: 'win32-x64', fetch: false };
  await assert.rejects(fetchArtifact(options), /no download was attempted/);
  const filename = path.join(
    root,
    'cache',
    engine,
    'win32-x64',
    getArtifactManifest(engine, 'win32-x64').cacheName,
  );
  await fs.writeFile(filename, 'corrupt');
  await assert.rejects(fetchArtifact(options), /integrity mismatch/);
  assert.equal(await fs.readFile(filename, 'utf8'), 'corrupt');
});

test('outer experiment ZIPs are deterministic and preserve embedded archive bytes', async (t) => {
  const directory = await scratch(t),
    first = path.join(directory, 'first.zip'),
    second = path.join(directory, 'second.zip');
  const bytes = Buffer.from('upstream ZIP bytes are opaque'),
    entries = [
      { name: 'payload/upstream.zip', data: bytes },
      { name: 'README.md', data: 'instructions' },
    ];
  await writeStoredZip(first, entries);
  await writeStoredZip(second, [...entries].reverse());
  assert.deepEqual(await fs.readFile(first), await fs.readFile(second));
  const inspected = await inspectZip(first);
  assert.equal(inspected.entries.length, 2);
  assert.equal(inspected.unpackedBytes, bytes.length + 'instructions'.length);
  assert.ok((await fs.readFile(first)).includes(bytes));
  await assert.rejects(writeStoredZip(first, entries), /EEXIST/);
  await assert.rejects(
    writeStoredZip(path.join(directory, 'duplicate.zip'), [
      { name: 'A', data: '' },
      { name: 'a', data: '' },
    ]),
    /duplicate/,
  );
});

test('ZIP inspection rejects traversal, dangerous symlink chains and writes through links', async (t) => {
  const directory = await scratch(t);
  for (const name of [
    '../escape',
    '/absolute',
    'C:/volume',
    'a\\b',
    'a:stream',
    'a/../b',
    'a//b',
    'CON',
    'trailing.',
    'space ',
  ])
    assert.throws(() => safeArchiveName(name));
  const traversal = path.join(directory, 'traversal.zip');
  await fixtureZip(traversal, [{ name: 'safe.txt', data: 'x' }]);
  const original = await fs.readFile(traversal);
  for (let offset = original.indexOf('safe.txt'); offset >= 0; offset = original.indexOf('safe.txt'))
    Buffer.from('../a.txt').copy(original, offset);
  await fs.writeFile(traversal, original);
  await assert.rejects(inspectZip(traversal), /traversal/);
  const escaped = path.join(directory, 'escaped.zip');
  await fixtureZip(escaped, [{ name: 'root/link', link: '../../outside' }]);
  await assert.rejects(inspectZip(escaped), /escapes/);
  const chained = path.join(directory, 'chain.zip');
  await fixtureZip(chained, [
    { name: 'a', link: '.' },
    { name: 'b', link: 'a/../outside' },
  ]);
  await assert.rejects(inspectZip(chained), /chain escapes/);
  const writesThrough = path.join(directory, 'writes.zip');
  await fixtureZip(writesThrough, [
    { name: 'a', link: 'b' },
    { name: 'a/file', data: 'x' },
  ]);
  await assert.rejects(inspectZip(writesThrough), /symlink ancestor/);
  const valid = path.join(directory, 'valid.zip');
  await fixtureZip(valid, [
    { name: 'App/Versions/159/file', data: 'binary' },
    { name: 'App/Versions/Current', link: '159' },
    { name: 'App/file', link: 'Versions/Current/file' },
  ]);
  assert.equal((await inspectZip(valid)).entries.length, 3);
});

test('runtime integrity detects byte changes, added files and outward links', async (t) => {
  const root = await scratch(t),
    directory = path.join(root, 'runtime'),
    outside = path.join(root, 'outside');
  await fs.mkdir(directory);
  await fs.mkdir(outside);
  await fs.writeFile(path.join(directory, 'binary'), 'first');
  const before = await treeIntegrity(directory);
  await fs.writeFile(path.join(directory, 'binary'), 'second');
  assert.notDeepEqual(await treeIntegrity(directory), before);
  await fs.writeFile(path.join(directory, 'added'), 'unexpected');
  assert.equal((await treeIntegrity(directory)).length, 2);
  await fs.symlink(
    outside,
    path.join(directory, 'escape'),
    process.platform === 'win32' ? 'junction' : 'dir',
  );
  await assert.rejects(treeIntegrity(directory), /redirects/);
});

test('version comparison keeps toolchain servicing requirements distinct', () => {
  assert.equal(versionAtLeast('17.12.4', '18.0.0'), false);
  assert.equal(versionAtLeast('18.0.0', '18.0.0'), true);
  assert.equal(versionAtLeast('10.0.28000.0', '10.0.28000.2270'), false);
  assert.equal(versionAtLeast('15.4', '15'), true);
  assert.equal(versionAtLeast('not-a-version', '15'), false);
});

test('standalone fixture dependency lock is complete and has no browser install scripts', () => {
  const metadata = require('../build/kit-package.json');
  const locked = require('../build/kit-package-lock.json');
  assert.deepEqual(metadata.devDependencies, locked.packages[''].devDependencies);
  assert.equal(metadata.engines.node, '>=24');
  assert.equal(metadata.scripts.postinstall, undefined);
  assert.equal(metadata.scripts.install, undefined);
  assert.equal(Object.keys(locked.packages).length, 4);
  for (const [name, version] of Object.entries(metadata.devDependencies))
    assert.equal(locked.packages[`node_modules/${name}`].version, version);
  for (const [location, entry] of Object.entries(locked.packages)) {
    if (!location) continue;
    assert.match(entry.integrity, /^sha512-/);
    assert.equal(new URL(entry.resolved).hostname, 'registry.npmjs.org');
    for (const [dependency, version] of Object.entries(entry.dependencies || {}))
      assert.equal(locked.packages[`node_modules/${dependency}`].version, version);
  }
});

test('standalone instructions use included entrypoints and distinguish native payloads', () => {
  for (const engine of ['chromium', 'brave'])
    for (const platform of ['win32-x64', 'darwin-arm64']) {
      const instructions = kitStartInstructions(getArtifactManifest(engine, platform));
      assert.match(instructions, /node cli\.cjs launch/);
      assert.match(instructions, /node record\.cjs/);
      assert.match(instructions, /npm ci --ignore-scripts/);
      assert.match(instructions, /separate from the runtime root/);
      assert.ok(instructions.includes(`--engine ${engine} --platform ${platform}`));
      assert.equal(instructions.includes('node experiments/'), false);
      assert.equal(instructions.includes('npx playwright install'), false);
      if (engine === 'brave') assert.match(instructions, /--workspace is not supported/);
    }
});
