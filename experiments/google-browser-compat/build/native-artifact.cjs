#!/usr/bin/env node
'use strict';

// Imports an explicitly selected, unsigned CI artifact. Never downloads or
// compiles code, changes installed apps, or attaches browser automation.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile, spawn } = require('node:child_process');
const { promisify } = require('node:util');
const execute = promisify(execFile);
const lock = require('./native-build.lock.json');
const branding = require('../native-branding/manifest.json');
const { ensureRoot, assertContained, assertRegularMarker } = require('../lib/paths.cjs');
const { digests, inspectZip, safeArchiveName } = require('../lib/artifacts.cjs');
const { windowsInventory, macInventory } = require('./runtime-inventory.cjs');
const { validateStartURL, manualEnvironment } = require('../cli.cjs');
const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');
const isDigest = (value) => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const host = () => `${process.platform}-${process.arch}`;
const KIND = 'zacro-imported-native-artifact';
const ROLES = ['regular-a', 'regular-b', 'private'];

function ciRunURL(value) {
  const url = new URL(value);
  if (
    url.protocol !== 'https:' ||
    url.hostname !== 'github.com' ||
    url.port ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !/^\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/actions\/runs\/[1-9][0-9]*(?:\/attempts\/[1-9][0-9]*)?\/?$/.test(
      url.pathname,
    )
  )
    throw new Error('Record the trusted GitHub Actions run URL without credentials, queries or fragments.');
  return url.href;
}

function options(argv) {
  const [command, ...rest] = argv;
  const allowed = {
    import: ['root', 'archive', 'package-receipt', 'build-receipt', 'ci-run'],
    verify: ['root', 'artifact'],
    launch: ['root', 'artifact', 'role', 'url'],
  };
  if (!allowed[command]) throw new Error('Use import, verify or launch.');
  const result = { command };
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index].slice(2);
    if (
      !rest[index].startsWith('--') ||
      !allowed[command].includes(key) ||
      Object.hasOwn(result, key) ||
      !rest[index + 1] ||
      rest[index + 1].startsWith('--')
    )
      throw new Error('Invalid or repeated native artifact option.');
    result[key] = rest[index + 1];
  }
  if (command === 'import') {
    for (const key of ['archive', 'package-receipt', 'build-receipt'])
      if (!path.isAbsolute(result[key] || ''))
        throw new Error('Select explicit absolute local archive and receipt paths.');
    result['ci-run'] = ciRunURL(result['ci-run']);
  } else if (!isDigest(result.artifact))
    throw new Error('Select the SHA-256 artifact ID returned by import.');
  if (command === 'launch') {
    if (!ROLES.includes(result.role)) throw new Error('Choose regular-a, regular-b or private.');
    validateStartURL(result.url);
  }
  return result;
}

async function jsonFile(filename) {
  if (!path.isAbsolute(filename || '')) throw new Error('Receipt paths must be absolute.');
  await assertRegularMarker(filename);
  const size = (await fs.stat(filename)).size;
  if (!size || size > 16 * 1024 ** 2) throw new Error('Receipt size is invalid.');
  const bytes = await fs.readFile(filename);
  return { value: JSON.parse(bytes.toString('utf8')), bytes, sha256: sha256(bytes) };
}

async function validateReceipts(packaged, built) {
  for (const receipt of [packaged, built]) {
    if (
      !receipt ||
      receipt.schemaVersion !== 1 ||
      receipt.compiled !== true ||
      receipt.productName !== lock.productName ||
      receipt.sourceVersion !== lock.sourceVersion ||
      receipt.sourceRevision !== lock.sourceRevision ||
      !lock.platforms.includes(receipt.platform) ||
      receipt.brandingPatchSha256 !== branding.patch.sha256 ||
      !isDigest(receipt.runtimeSha256) ||
      !isDigest(receipt.executableSha256)
    )
      throw new Error('Receipts must identify the pinned, compiled Zacro prototype.');
  }
  for (const field of ['platform', 'runtimeSha256', 'executableSha256'])
    if (built[field] !== packaged[field])
      throw new Error('Package and build receipts identify different runtimes.');
  if (
    !isDigest(packaged.sha256) ||
    !Number.isSafeInteger(packaged.size) ||
    packaged.size <= 0 ||
    packaged.size >= 4 * 1024 ** 3
  )
    throw new Error('Package archive identity is invalid.');
  if (
    built.depotToolsRevision !== lock.depotToolsRevision ||
    built.executableRelative !== branding.outputs[built.platform] ||
    !Array.isArray(built.files) ||
    !built.files.length ||
    built.files.length > 30000 ||
    !isDigest(built.configurationSha256) ||
    !Number.isFinite(Date.parse(built.configuredAt)) ||
    !Number.isFinite(Date.parse(built.builtAt))
  )
    throw new Error('A full compiled build receipt with the pinned toolchain and inventory is required.');
  const args = await fs.readFile(path.join(__dirname, `native-args.${built.platform}.gn`));
  if (built.gnArgsSha256 !== sha256(args))
    throw new Error('Native build arguments differ from the reviewed prototype.');
  const configured = Object.fromEntries(
    [
      'schemaVersion',
      'productName',
      'platform',
      'sourceVersion',
      'sourceRevision',
      'depotToolsRevision',
      'brandingPatchSha256',
      'gnArgsSha256',
      'syncEvidence',
      'configuredAt',
    ].map((key) => [key, built[key]]),
  );
  configured.compiled = false;
  if (sha256(JSON.stringify(configured)) !== built.configurationSha256)
    throw new Error('Compiled receipt configuration binding is invalid.');
  if (sha256(JSON.stringify(built.files)) !== built.runtimeSha256)
    throw new Error('Compiled runtime inventory digest is invalid.');
  const identities = new Set();
  for (const file of built.files) {
    if (!file || typeof file.path !== 'string' || /[\x00-\x1f\x7f]/.test(file.path))
      throw new Error('Invalid runtime inventory path.');
    safeArchiveName(file.path);
    const identity = file.path.toLowerCase();
    if (identities.has(identity)) throw new Error('Duplicate runtime inventory path.');
    identities.add(identity);
    if (built.platform === 'win32-x64') {
      if (!isDigest(file.sha256) || Object.keys(file).some((key) => !['path', 'sha256'].includes(key)))
        throw new Error('Invalid Windows runtime inventory.');
    } else {
      if (
        !(file.path === 'Zacro Prototype.app' || file.path.startsWith('Zacro Prototype.app/')) ||
        !['file', 'directory', 'symlink'].includes(file.type) ||
        !Number.isInteger(file.mode) ||
        file.mode < 0 ||
        file.mode > 0o7777 ||
        (file.type === 'file' && !isDigest(file.sha256)) ||
        (file.type === 'symlink' && typeof file.link !== 'string')
      )
        throw new Error('Invalid Mac runtime inventory.');
    }
  }
  if (
    !built.files.some(
      (file) => file.path === built.executableRelative && file.sha256 === built.executableSha256,
    )
  )
    throw new Error('Executable does not match the compiled runtime inventory.');
  return built;
}

function validateArchiveEntries(inspected, built) {
  const windows = built.platform === 'win32-x64';
  const expected = new Set(
    windows
      ? [
          ...built.files.map((file) => `Zacro Prototype/${file.path}`),
          'Zacro Prototype/NATIVE-BUILD.json',
          'Zacro Prototype/LICENSE.chromium',
        ]
      : built.files.map((file) => file.path),
  );
  const ancestors = new Set();
  for (const name of expected) {
    const parts = name.split('/');
    for (let index = 1; index < parts.length; index++) ancestors.add(parts.slice(0, index).join('/'));
  }
  const found = new Set();
  for (const entry of inspected.entries) {
    safeArchiveName(entry.name);
    const name = entry.name.replace(/\/$/, '');
    // ditto consumes AppleDouble resource metadata during native Mac extraction.
    // Root attributes use __MACOSX/._Zacro Prototype.app; nested metadata must
    // also map to a real inventoried member rather than any arbitrary descendant.
    if (!windows && name === '__MACOSX' && entry.name.endsWith('/')) continue;
    if (!windows && name.startsWith('__MACOSX/')) {
      const relative = name.slice('__MACOSX/'.length);
      const base = path.posix.basename(relative);
      const mapped =
        base.startsWith('._') && base.length > 2
          ? path.posix.join(path.posix.dirname(relative), base.slice(2))
          : null;
      if (
        (entry.mode & 0xf000) !== 0xa000 &&
        ((entry.name.endsWith('/') && (expected.has(relative) || ancestors.has(relative))) ||
          (mapped && (expected.has(mapped) || ancestors.has(mapped))))
      )
        continue;
      throw new Error('Mac resource metadata does not map to the compiled bundle inventory.');
    }
    if (!(expected.has(name) || (entry.name.endsWith('/') && ancestors.has(name))))
      throw new Error('Archive contains entries outside the compiled package inventory.');
    if (windows && (entry.mode & 0xf000) === 0xa000)
      throw new Error('Windows packages must not contain symbolic links.');
    found.add(name);
  }
  for (const file of built.files)
    if (
      (windows || file.type !== 'directory') &&
      !found.has(windows ? `Zacro Prototype/${file.path}` : file.path)
    )
      throw new Error('Archive is missing a compiled runtime entry.');
  if (
    windows &&
    (!found.has('Zacro Prototype/NATIVE-BUILD.json') || !found.has('Zacro Prototype/LICENSE.chromium'))
  )
    throw new Error('Windows package metadata is missing.');
}

function artifactDirectory(root, platform, artifact) {
  if (!lock.platforms.includes(platform) || !isDigest(artifact))
    throw new Error('Invalid native artifact selection.');
  return path.join(root, 'imported-native', lock.sourceVersion, platform, artifact);
}

async function runtimeInventory(directory, built) {
  const payload = path.join(directory, 'payload');
  const top = await fs.readdir(payload);
  const expectedTop = built.platform === 'win32-x64' ? 'Zacro Prototype' : 'Zacro Prototype.app';
  if (JSON.stringify(top) !== JSON.stringify([expectedTop]))
    throw new Error('Extracted package contains unexpected top-level content.');
  const runtime = await assertContained(directory, path.join(payload, expectedTop));
  let files,
    metadata = {};
  if (built.platform === 'win32-x64') {
    const embedded = await jsonFile(path.join(runtime, 'NATIVE-BUILD.json'));
    const expectedMetadata = { ...built };
    delete expectedMetadata.files;
    if (JSON.stringify(embedded.value) !== JSON.stringify(expectedMetadata))
      throw new Error('Embedded build receipt differs from the full CI receipt.');
    const license = path.join(runtime, 'LICENSE.chromium');
    await assertRegularMarker(license);
    metadata = { embeddedBuildSha256: embedded.sha256, licenseSha256: (await digests(license)).sha256 };
    const names = (await fs.readdir(runtime)).filter(
      (name) => !['NATIVE-BUILD.json', 'LICENSE.chromium'].includes(name),
    );
    files = await windowsInventory(runtime, names.join('\n'));
  } else files = await macInventory(runtime);
  if (
    JSON.stringify(files) !== JSON.stringify(built.files) ||
    sha256(JSON.stringify(files)) !== built.runtimeSha256
  )
    throw new Error('Extracted runtime does not exactly match the compiled inventory.');
  const executable = await assertContained(
    directory,
    path.join(payload, built.platform === 'win32-x64' ? 'Zacro Prototype' : '', built.executableRelative),
  );
  if ((await digests(executable)).sha256 !== built.executableSha256)
    throw new Error('Imported executable digest differs.');
  return { executable, metadata };
}

async function verifyImported({ root: input, artifact }) {
  const root = await ensureRoot(input, { create: false });
  const directory = await assertContained(root, artifactDirectory(root, host(), artifact));
  const names = (await fs.readdir(directory)).sort();
  if (JSON.stringify(names) !== JSON.stringify(['IMPORT.json', 'build.json', 'package.json', 'payload']))
    throw new Error('Import is incomplete or contains unexpected files; existing files were retained.');
  const imported = (await jsonFile(path.join(directory, 'IMPORT.json'))).value;
  const packaged = await jsonFile(path.join(directory, 'package.json'));
  const built = await jsonFile(path.join(directory, 'build.json'));
  await validateReceipts(packaged.value, built.value);
  if (
    imported.schemaVersion !== 1 ||
    imported.kind !== KIND ||
    imported.locallyCompiled !== false ||
    imported.sourceBuildReported !== true ||
    imported.productName !== lock.productName ||
    imported.sourceVersion !== lock.sourceVersion ||
    imported.signedForDistribution !== false ||
    imported.googleAcceptance !== 'untested' ||
    !Number.isFinite(Date.parse(imported.importedAt)) ||
    imported.ciProvenance !== 'operator-supplied; unsigned receipts do not authenticate the CI origin' ||
    imported.artifactId !== artifact ||
    imported.archiveSha256 !== artifact ||
    packaged.value.sha256 !== artifact ||
    imported.archiveSize !== packaged.value.size ||
    imported.platform !== host() ||
    built.value.platform !== host() ||
    imported.buildReceiptSha256 !== built.sha256 ||
    imported.packageReceiptSha256 !== packaged.sha256 ||
    imported.runtimeSha256 !== built.value.runtimeSha256 ||
    imported.executableSha256 !== built.value.executableSha256 ||
    imported.sourceRevision !== lock.sourceRevision ||
    imported.brandingPatchSha256 !== branding.patch.sha256
  )
    throw new Error('Import completion receipt does not match the selected artifact.');
  ciRunURL(imported.ciRunUrl);
  const runtime = await runtimeInventory(directory, built.value);
  if (JSON.stringify(runtime.metadata) !== JSON.stringify(imported.packageMetadata))
    throw new Error('Imported package metadata changed.');
  return { root, directory, imported, buildReceipt: built.value, executable: runtime.executable };
}

async function importArtifact(args) {
  const ciRunUrl = ciRunURL(args['ci-run']);
  for (const key of ['archive', 'package-receipt', 'build-receipt'])
    if (!path.isAbsolute(args[key] || '')) throw new Error('Select absolute local artifact paths.');
  const packaged = await jsonFile(args['package-receipt']);
  const built = await jsonFile(args['build-receipt']);
  await validateReceipts(packaged.value, built.value);
  if (built.value.platform !== host())
    throw new Error('Import and launch require the matching native OS and architecture.');
  await assertRegularMarker(args.archive);
  const archive = await digests(args.archive);
  if (archive.sha256 !== packaged.value.sha256 || archive.size !== packaged.value.size)
    throw new Error('Selected archive does not match its package receipt.');
  const inspected = await inspectZip(args.archive);
  validateArchiveEntries(inspected, built.value);
  const root = await ensureRoot(args.root);
  const directory = await assertContained(
    root,
    artifactDirectory(root, built.value.platform, archive.sha256),
  );
  try {
    await fs.lstat(directory);
    const existing = await verifyImported({ root, artifact: archive.sha256 });
    if (
      existing.imported.ciRunUrl !== ciRunUrl ||
      existing.imported.buildReceiptSha256 !== built.sha256 ||
      existing.imported.packageReceiptSha256 !== packaged.sha256
    )
      throw new Error('Existing import has different provenance receipts; it was retained.');
    return existing.imported;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const disk = await fs.statfs(root);
  if (disk.bavail * disk.bsize < inspected.unpackedBytes + 1024 ** 3)
    throw new Error('Insufficient free space for extraction and reserve.');
  await fs.mkdir(path.dirname(directory), { recursive: true });
  await fs.mkdir(directory);
  await fs.writeFile(path.join(directory, 'build.json'), built.bytes, { flag: 'wx' });
  await fs.writeFile(path.join(directory, 'package.json'), packaged.bytes, { flag: 'wx' });
  const payload = path.join(directory, 'payload');
  await fs.mkdir(payload);
  if (process.platform === 'win32') {
    await execute(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        " $ErrorActionPreference = 'Stop'; Expand-Archive -LiteralPath $env:ZACRO_IMPORT_ARCHIVE -DestinationPath $env:ZACRO_IMPORT_PAYLOAD",
      ],
      {
        windowsHide: true,
        timeout: 10 * 60 * 1000,
        maxBuffer: 2 * 1024 ** 2,
        env: { ...manualEnvironment(), ZACRO_IMPORT_ARCHIVE: args.archive, ZACRO_IMPORT_PAYLOAD: payload },
      },
    );
  } else
    await execute('/usr/bin/ditto', ['-x', '-k', args.archive, payload], {
      timeout: 10 * 60 * 1000,
      maxBuffer: 2 * 1024 ** 2,
      env: manualEnvironment(),
    });
  if ((await digests(args.archive)).sha256 !== archive.sha256)
    throw new Error('Archive changed during import. No completion receipt was issued.');
  const runtime = await runtimeInventory(directory, built.value);
  const imported = {
    schemaVersion: 1,
    kind: KIND,
    importedAt: new Date().toISOString(),
    artifactId: archive.sha256,
    productName: lock.productName,
    platform: built.value.platform,
    sourceVersion: lock.sourceVersion,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: branding.patch.sha256,
    archiveSha256: archive.sha256,
    archiveSize: archive.size,
    runtimeSha256: built.value.runtimeSha256,
    executableSha256: built.value.executableSha256,
    buildReceiptSha256: built.sha256,
    packageReceiptSha256: packaged.sha256,
    packageMetadata: runtime.metadata,
    ciRunUrl,
    ciProvenance: 'operator-supplied; unsigned receipts do not authenticate the CI origin',
    sourceBuildReported: true,
    locallyCompiled: false,
    signedForDistribution: false,
    googleAcceptance: 'untested',
  };
  await fs.writeFile(path.join(directory, 'IMPORT.json'), JSON.stringify(imported, null, 2) + '\n', {
    flag: 'wx',
  });
  return (await verifyImported({ root, artifact: archive.sha256 })).imported;
}

async function ensureImportedProfile(runtime, role) {
  if (!ROLES.includes(role)) throw new Error('Choose regular-a, regular-b or private.');
  const directory = await assertContained(
    runtime.root,
    path.join(runtime.root, 'profiles', 'zacro-native-import', host(), runtime.imported.runtimeSha256, role),
  );
  await fs.mkdir(directory, { recursive: true });
  const expected = {
    schemaVersion: 1,
    kind: 'manual-imported-zacro-profile',
    platform: host(),
    runtimeSha256: runtime.imported.runtimeSha256,
    executableSha256: runtime.imported.executableSha256,
    role,
  };
  const marker = path.join(directory, '.zacro-native-profile.json');
  const entries = await fs.readdir(directory);
  if (!entries.includes(path.basename(marker))) {
    if (entries.length) throw new Error('Refusing to adopt an existing profile.');
    await fs.writeFile(marker, JSON.stringify(expected, null, 2) + '\n', { flag: 'wx' });
  }
  if (JSON.stringify((await jsonFile(marker)).value) !== JSON.stringify(expected))
    throw new Error('Imported profile ownership differs.');
  return directory;
}

function launchFlags(profile, role, url) {
  if (!path.isAbsolute(profile || '') || !ROLES.includes(role))
    throw new Error('Invalid isolated manual profile.');
  return [
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--profile-directory=Default',
    ...(role === 'private' ? ['--incognito'] : []),
    validateStartURL(url),
  ];
}

async function launchImported(args) {
  validateStartURL(args.url);
  if (!ROLES.includes(args.role)) throw new Error('Choose regular-a, regular-b or private.');
  const runtime = await verifyImported(args);
  const profile = await ensureImportedProfile(runtime, args.role);
  const child = spawn(runtime.executable, launchFlags(profile, args.role, args.url), {
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
  const receipt = {
    schemaVersion: 1,
    kind: 'manual-imported-native-launch',
    launchedAt: new Date().toISOString(),
    artifactId: runtime.imported.artifactId,
    platform: host(),
    runtimeSha256: runtime.imported.runtimeSha256,
    executableSha256: runtime.imported.executableSha256,
    sourceRevision: lock.sourceRevision,
    brandingPatchSha256: branding.patch.sha256,
    ciRunUrl: runtime.imported.ciRunUrl,
    role: args.role,
    processId: child.pid,
    locallyCompiled: false,
    automationAttached: false,
    googleAcceptance: 'untested',
  };
  const filename = await assertContained(
    runtime.root,
    path.join(runtime.root, 'launches', `native-import-${crypto.randomUUID()}.json`),
  );
  await fs.mkdir(path.dirname(filename), { recursive: true });
  await fs.writeFile(filename, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  return { ...receipt, profileDirectory: profile, receiptPath: filename };
}

async function main(argv = process.argv.slice(2)) {
  const args = options(argv);
  if (args.command === 'import') return importArtifact(args);
  if (args.command === 'verify') return (await verifyImported(args)).imported;
  return launchImported(args);
}
if (require.main === module)
  main()
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
module.exports = {
  options,
  ciRunURL,
  validateReceipts,
  validateArchiveEntries,
  artifactDirectory,
  importArtifact,
  verifyImported,
  ensureImportedProfile,
  launchFlags,
  launchImported,
  main,
};
