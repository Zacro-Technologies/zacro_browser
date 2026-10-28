'use strict';
const fs = require('node:fs/promises');
const { createReadStream, createWriteStream } = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { spawn } = require('node:child_process');
const { pipeline } = require('node:stream/promises');
const { Readable } = require('node:stream');
const { ensureRoot, assertContained, toolkitRoot, readJSON, assertRegularMarker } = require('./paths.cjs');
const lock = require('../engines.lock.json');
const RECEIPT = '.zacro-runtime.json';
function getArtifactManifest(engine, platform) {
  const selected = lock.engines[engine];
  const artifact = selected?.artifacts[platform];
  if (!artifact) throw new Error(`No pinned artifact for ${engine}/${platform}.`);
  return {
    engine,
    platform,
    version: selected.version,
    sourceRevision: selected.sourceRevision,
    classification: selected.classification,
    ...artifact,
  };
}
async function digests(filename) {
  const sha256 = crypto.createHash('sha256'),
    md5 = crypto.createHash('md5');
  let size = 0;
  for await (const chunk of createReadStream(filename)) {
    size += chunk.length;
    sha256.update(chunk);
    md5.update(chunk);
  }
  return { size, sha256: sha256.digest('hex'), md5Base64: md5.digest('base64') };
}
function validateArtifactURL(artifact) {
  const url = new URL(artifact.url);
  if (!/^[a-f0-9]{64}$/.test(artifact.sha256 || ''))
    throw new Error('Every pinned archive requires a recorded SHA-256.');
  if (url.protocol !== 'https:' || url.username || url.password)
    throw new Error('Artifact URL must use authenticated HTTPS.');
  if (url.hostname === 'github.com') {
    if (
      !url.pathname.startsWith('/brave/brave-browser/releases/download/') ||
      !/^[a-f0-9]{64}$/.test(artifact.sha256 || '')
    )
      throw new Error('Brave artifacts require the pinned publisher SHA-256.');
  } else if (url.hostname === 'storage.googleapis.com') {
    if (
      !url.pathname.startsWith('/download/storage/v1/b/chromium-browser-snapshots/o/') ||
      url.searchParams.get('generation') !== artifact.generation ||
      !/^\d+$/.test(artifact.generation || '') ||
      !/^[A-Za-z0-9+/]{22}==$/.test(artifact.md5Base64 || '')
    )
      throw new Error('Chromium artifact must pin its official object generation and published digest.');
  } else throw new Error('Unrecognized upstream artifact host.');
  if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0 || artifact.size > 2 * 1024 ** 3)
    throw new Error('Invalid artifact size limit.');
  return url;
}
async function verifyArchive(filename, artifact) {
  validateArtifactURL(artifact);
  await assertRegularMarker(filename);
  const result = await digests(filename);
  if (
    result.size !== artifact.size ||
    (artifact.sha256 && result.sha256 !== artifact.sha256) ||
    (artifact.md5Base64 && result.md5Base64 !== artifact.md5Base64)
  )
    throw new Error('Artifact integrity mismatch; existing files and profiles were not replaced.');
  return {
    ...result,
    sha256Provenance: artifact.sha256Provenance,
    expectedGeneration: artifact.generation || null,
  };
}
async function exists(filename) {
  try {
    await fs.lstat(filename);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}
async function fetchArtifact({ root: input, engine, platform, fetch: allowNetwork = true }) {
  const root = await ensureRoot(input);
  const artifact = getArtifactManifest(engine, platform);
  validateArtifactURL(artifact);
  const filename = await assertContained(
    root,
    path.join(root, 'cache', engine, platform, artifact.cacheName),
  );
  await fs.mkdir(path.dirname(filename), { recursive: true });
  if (!(await exists(filename))) {
    const payload = path.join(toolkitRoot, 'payload', artifact.cacheName);
    if (await exists(payload)) {
      await verifyArchive(payload, artifact);
      await fs.copyFile(payload, filename, require('node:fs').constants.COPYFILE_EXCL);
    } else {
      if (!allowNetwork)
        throw new Error('Pinned archive is missing. Run fetch first; no download was attempted.');
      const temporary = filename + `.part-${crypto.randomUUID()}`;
      try {
        const response = await globalThis.fetch(artifact.url, {
          signal: AbortSignal.timeout(20 * 60 * 1000),
        });
        if (!response.ok || !response.body) throw new Error(`Upstream download failed (${response.status}).`);
        const redirected = new URL(response.url);
        if (
          redirected.protocol !== 'https:' ||
          !['storage.googleapis.com', 'github.com', 'release-assets.githubusercontent.com'].includes(
            redirected.hostname,
          )
        )
          throw new Error('Unexpected artifact redirect host.');
        const generation = response.headers.get('x-goog-generation');
        if (artifact.generation && generation !== artifact.generation)
          throw new Error('Storage generation did not match the pin.');
        const declared = response.headers.get('content-length');
        if (declared && Number(declared) !== artifact.size)
          throw new Error('Upstream declared an unexpected artifact size.');
        let received = 0;
        const bounded = async function* (source) {
          for await (const chunk of source) {
            received += chunk.length;
            if (received > artifact.size) throw new Error('Artifact exceeded its pinned byte limit.');
            yield chunk;
          }
        };
        await pipeline(
          Readable.fromWeb(response.body),
          bounded,
          createWriteStream(temporary, { flags: 'wx' }),
        );
        await verifyArchive(temporary, artifact);
        await fs.copyFile(temporary, filename, require('node:fs').constants.COPYFILE_EXCL);
      } finally {
        await fs.unlink(temporary).catch((error) => {
          if (error.code !== 'ENOENT') throw error;
        });
      }
    }
  }
  return { root, filename, artifact, integrity: await verifyArchive(filename, artifact) };
}

function safeArchiveName(name) {
  if (!name || name.includes('\0') || name.includes('\\') || name.startsWith('/') || /^[A-Za-z]:/.test(name))
    throw new Error('Unsafe ZIP entry path.');
  const segments = name.replace(/\/$/, '').split('/');
  if (segments.some((part) => part === '..' || part === '.' || part.includes(':')))
    throw new Error('ZIP traversal or alternate stream is not allowed.');
  if (
    segments.some(
      (part) =>
        !part ||
        part.trimEnd() !== part ||
        part.endsWith('.') ||
        /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(part),
    )
  )
    throw new Error('Ambiguous platform-specific ZIP path.');
  return name;
}
async function inspectZip(filename) {
  const file = await fs.open(filename, 'r');
  try {
    const { size } = await file.stat();
    const tail = Buffer.alloc(Math.min(size, 65557));
    await file.read(tail, 0, tail.length, size - tail.length);
    let end = -1;
    for (let offset = tail.length - 22; offset >= 0; offset--)
      if (
        tail.readUInt32LE(offset) === 0x06054b50 &&
        offset + 22 + tail.readUInt16LE(offset + 20) === tail.length
      ) {
        end = offset;
        break;
      }
    if (end < 0) throw new Error('ZIP directory is missing.');
    const count = tail.readUInt16LE(end + 10),
      directorySize = tail.readUInt32LE(end + 12),
      directoryOffset = tail.readUInt32LE(end + 16);
    if (
      tail.readUInt16LE(end + 4) ||
      tail.readUInt16LE(end + 6) ||
      count === 65535 ||
      directoryOffset === 0xffffffff ||
      count > 30000 ||
      directorySize > 32 * 1024 ** 2 ||
      directoryOffset + directorySize > size
    )
      throw new Error('Unsupported or unbounded ZIP directory.');
    const directory = Buffer.alloc(directorySize);
    await file.read(directory, 0, directory.length, directoryOffset);
    let offset = 0,
      unpackedBytes = 0;
    const names = new Set(),
      entries = [],
      links = new Map();
    for (let index = 0; index < count; index++) {
      if (offset + 46 > directory.length || directory.readUInt32LE(offset) !== 0x02014b50)
        throw new Error('Malformed ZIP entry.');
      const flags = directory.readUInt16LE(offset + 8),
        method = directory.readUInt16LE(offset + 10);
      const compressed = directory.readUInt32LE(offset + 20),
        size = directory.readUInt32LE(offset + 24);
      const nameLength = directory.readUInt16LE(offset + 28),
        extraLength = directory.readUInt16LE(offset + 30),
        commentLength = directory.readUInt16LE(offset + 32);
      const mode = directory.readUInt32LE(offset + 38) >>> 16,
        localOffset = directory.readUInt32LE(offset + 42);
      const next = offset + 46 + nameLength + extraLength + commentLength;
      if (next > directory.length || flags & 1 || ![0, 8].includes(method))
        throw new Error('Unsupported ZIP encoding.');
      const name = safeArchiveName(
        directory.subarray(offset + 46, offset + 46 + nameLength).toString('utf8'),
      );
      const identity = name.toLowerCase();
      if (names.has(identity)) throw new Error('ZIP contains duplicate or case-colliding paths.');
      names.add(identity);
      unpackedBytes += size;
      if (unpackedBytes > 8 * 1024 ** 3) throw new Error('Archive extraction exceeds the experiment limit.');
      if ((mode & 0xf000) === 0xa000) {
        if (size > 4096 || compressed > 8192) throw new Error('ZIP symlink target is unbounded.');
        const header = Buffer.alloc(30);
        await file.read(header, 0, 30, localOffset);
        if (header.readUInt32LE(0) !== 0x04034b50) throw new Error('Malformed ZIP local header.');
        const start = localOffset + 30 + header.readUInt16LE(26) + header.readUInt16LE(28);
        const data = Buffer.alloc(compressed);
        await file.read(data, 0, compressed, start);
        const target = (method === 8 ? zlib.inflateRawSync(data, { maxOutputLength: 4096 }) : data).toString(
          'utf8',
        );
        if (
          !target ||
          target.includes('\0') ||
          target.includes('\\') ||
          path.posix.isAbsolute(target) ||
          /^[A-Za-z]:/.test(target)
        )
          throw new Error('Unsafe ZIP symlink.');
        const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(name), target));
        if (resolved === '..' || resolved.startsWith('../'))
          throw new Error('ZIP symlink escapes extraction root.');
        links.set(name.replace(/\/$/, ''), target);
      }
      entries.push({ name, size, mode });
      offset = next;
    }
    if (offset !== directory.length) throw new Error('ZIP directory length mismatch.');
    for (const entry of entries) {
      const parts = entry.name.replace(/\/$/, '').split('/');
      for (let index = 1; index < parts.length; index++)
        if (links.has(parts.slice(0, index).join('/')))
          throw new Error('ZIP writes through a symlink ancestor.');
    }
    // Resolve symlink chains with real path semantics, including .. after a
    // link component, before handing the archive to a native extractor.
    for (const [name, target] of links) {
      const pending = [...path.posix.dirname(name).split('/'), ...target.split('/')],
        resolved = [];
      let expansions = 0;
      while (pending.length) {
        const part = pending.shift();
        if (!part || part === '.') continue;
        if (part === '..') {
          if (!resolved.length) throw new Error('ZIP symlink chain escapes extraction root.');
          resolved.pop();
          continue;
        }
        const current = [...resolved, part].join('/');
        if (links.has(current)) {
          if (++expansions > 64) throw new Error('ZIP symlink chain is cyclic or too deep.');
          pending.unshift(...links.get(current).split('/'));
        } else resolved.push(part);
      }
    }
    return { entries, unpackedBytes };
  } finally {
    await file.close();
  }
}
function run(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], ...options });
    let errorOutput = '';
    child.stderr?.on('data', (chunk) => {
      errorOutput = (errorOutput + chunk).slice(-4000);
    });
    child.stdout?.resume();
    child.once('error', reject);
    child.once('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`${program} failed (${code}): ${errorOutput}`)),
    );
  });
}
async function treeIntegrity(directory) {
  const entries = [];
  async function visit(relative = '') {
    for (const name of (await fs.readdir(path.join(directory, relative))).sort()) {
      if (!relative && name === RECEIPT) continue;
      const location = path.join(directory, relative, name),
        key = path.posix.join(relative.split(path.sep).join('/'), name);
      const stat = await fs.lstat(location);
      if (stat.isSymbolicLink()) {
        await assertContained(directory, location);
        entries.push({ path: key, link: await fs.readlink(location) });
      } else if (stat.isDirectory()) await visit(path.join(relative, name));
      else if (stat.isFile()) entries.push({ path: key, sha256: (await digests(location)).sha256 });
      else throw new Error('Unexpected runtime filesystem entry.');
    }
  }
  await visit();
  return entries;
}
async function prepareRuntime(options) {
  const requestedArtifact = getArtifactManifest(options.engine, options.platform);
  if (`${process.platform}-${process.arch}` !== requestedArtifact.platform)
    throw new Error(
      'Extract and execute this runtime on its matching native operating system and architecture. Fetch/assemble can run elsewhere.',
    );
  const { root, filename, artifact, integrity } = await fetchArtifact(options);
  const runtimeDirectory = await assertContained(
    root,
    path.join(root, 'runtimes', artifact.engine, artifact.platform, artifact.version),
  );
  const receiptPath = path.join(runtimeDirectory, RECEIPT);
  if (!(await exists(runtimeDirectory))) {
    const inspected = await inspectZip(filename);
    const disk = await fs.statfs(root);
    if (disk.bavail * disk.bsize < inspected.unpackedBytes + 1024 ** 3)
      throw new Error('Insufficient free space for extraction and reserve.');
    await fs.mkdir(runtimeDirectory, { recursive: true });
    if (process.platform === 'win32') {
      await run(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Expand-Archive -LiteralPath $env:ZACRO_ARCHIVE_PATH -DestinationPath $env:ZACRO_EXTRACT_PATH',
        ],
        { env: { ...process.env, ZACRO_ARCHIVE_PATH: filename, ZACRO_EXTRACT_PATH: runtimeDirectory } },
      );
    } else await run('/usr/bin/ditto', ['-x', '-k', filename, runtimeDirectory]);
    const executable = await assertContained(root, path.join(runtimeDirectory, artifact.executable));
    if (!(await exists(executable)))
      throw new Error('Expected upstream executable is absent; runtime was not relabeled or guessed.');
    const receipt = {
      schemaVersion: 1,
      engine: artifact.engine,
      platform: artifact.platform,
      version: artifact.version,
      sourceRevision: artifact.sourceRevision,
      archive: {
        sha256: integrity.sha256,
        size: integrity.size,
        expectedGeneration: integrity.expectedGeneration,
        sha256Provenance: integrity.sha256Provenance,
      },
      executable: artifact.executable,
      files: await treeIntegrity(runtimeDirectory),
    };
    await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  }
  if (!(await exists(receiptPath)))
    throw new Error(
      'Existing runtime has no completion receipt. It was left intact; choose a fresh experiment root to recover.',
    );
  await assertRegularMarker(receiptPath);
  const receipt = await readJSON(receiptPath);
  if (
    receipt.schemaVersion !== 1 ||
    receipt.engine !== artifact.engine ||
    receipt.platform !== artifact.platform ||
    receipt.version !== artifact.version ||
    receipt.sourceRevision !== artifact.sourceRevision ||
    receipt.executable !== artifact.executable ||
    receipt.archive?.sha256 !== integrity.sha256
  )
    throw new Error('Runtime receipt does not match the pinned upstream archive.');
  const actual = await treeIntegrity(runtimeDirectory);
  if (JSON.stringify(actual) !== JSON.stringify(receipt.files))
    throw new Error('Extracted runtime changed after verification. It was not replaced or launched.');
  return {
    executable: path.join(runtimeDirectory, artifact.executable),
    runtimeDirectory,
    receipt,
    artifact,
    root,
  };
}

// Stored outer ZIPs preserve the original upstream ZIP byte-for-byte. No Mac
// bundle is unpacked or rewritten on Windows. Fixed timestamps/sorted entries
// make identical source inputs produce identical experiment archives.
const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  return value >>> 0;
});
function crcChunk(crc, chunk) {
  for (const byte of chunk) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return crc >>> 0;
}
async function writeStoredZip(destination, entries) {
  if (
    entries.length > 30000 ||
    new Set(entries.map((entry) => safeArchiveName(entry.name).toLowerCase())).size !== entries.length
  )
    throw new Error('Outer ZIP has too many or duplicate entries.');
  const output = await fs.open(destination, 'wx');
  const central = [];
  let position = 0;
  const write = async (data) => {
    let written = 0;
    while (written < data.length)
      written += (await output.write(data, written, data.length - written, position + written)).bytesWritten;
    position += data.length;
  };
  try {
    for (const entry of [...entries].sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
      safeArchiveName(entry.name);
      const name = Buffer.from(entry.name),
        bytes = entry.data && Buffer.from(entry.data);
      let crc = 0xffffffff,
        size = 0;
      if (bytes) {
        crc = crcChunk(crc, bytes);
        size = bytes.length;
      } else
        for await (const chunk of createReadStream(entry.source)) {
          crc = crcChunk(crc, chunk);
          size += chunk.length;
        }
      crc = (crc ^ 0xffffffff) >>> 0;
      if (size >= 0xffffffff || position >= 0xffffffff)
        throw new Error('Outer ZIP exceeds its supported size.');
      const start = position,
        local = Buffer.alloc(30);
      local.writeUInt32LE(0x04034b50, 0);
      local.writeUInt16LE(20, 4);
      local.writeUInt16LE(0x800, 6);
      local.writeUInt16LE(0x2821, 12);
      local.writeUInt32LE(crc, 14);
      local.writeUInt32LE(size, 18);
      local.writeUInt32LE(size, 22);
      local.writeUInt16LE(name.length, 26);
      await write(local);
      await write(name);
      if (bytes) await write(bytes);
      else for await (const chunk of createReadStream(entry.source)) await write(chunk);
      const record = Buffer.alloc(46);
      record.writeUInt32LE(0x02014b50, 0);
      record.writeUInt16LE(0x314, 4);
      record.writeUInt16LE(20, 6);
      record.writeUInt16LE(0x800, 8);
      record.writeUInt16LE(0x2821, 14);
      record.writeUInt32LE(crc, 16);
      record.writeUInt32LE(size, 20);
      record.writeUInt32LE(size, 24);
      record.writeUInt16LE(name.length, 28);
      record.writeUInt32LE((0o100644 << 16) >>> 0, 38);
      record.writeUInt32LE(start, 42);
      central.push(record, name);
    }
    const centralStart = position;
    for (const part of central) await write(part);
    const ending = Buffer.alloc(22);
    ending.writeUInt32LE(0x06054b50, 0);
    ending.writeUInt16LE(entries.length, 8);
    ending.writeUInt16LE(entries.length, 10);
    ending.writeUInt32LE(position - centralStart, 12);
    ending.writeUInt32LE(centralStart, 16);
    await write(ending);
  } finally {
    await output.close();
  }
}
function kitStartInstructions(artifact) {
  const root =
    artifact.platform === 'win32-x64' ? 'C:\\zacro-google-prototype' : '"$HOME/zacro-google-prototype"';
  const selection = `--engine ${artifact.engine} --platform ${artifact.platform} --root ${root}`;
  return [
    'Zacro Google website compatibility experiment — standalone kit',
    '',
    `Payload: ${artifact.engine} ${artifact.version} (${artifact.platform})`,
    `Classification: ${artifact.classification}`,
    'This is not a compiled Zacro fork, a Google compatibility result, or a production release.',
    '',
    '1. Extract the outer ZIP to a fresh folder separate from the runtime root above.',
    '   Keep payload/ intact. The upstream browser ZIP is unpacked only on its native OS.',
    '2. Install Node.js 24 or later. Manual launch and recording need no npm dependencies.',
    '3. Open a terminal in the extracted zacro-google-browser-compat directory.',
    '4. Read docs/MANUAL-ACCEPTANCE.md before any account interaction.',
    '',
    `node cli.cjs preflight --platform ${artifact.platform} --root ${root}`,
    `node cli.cjs fetch ${selection}`,
    `node cli.cjs launch ${selection} --role regular-a`,
    `node record.cjs --root ${root} --init`,
    '',
    "fetch verifies and copies this kit's bundled archive to the owned cache; it does not",
    'need a browser download for this engine/platform. Each kit carries one upstream payload.',
    'preflight reports source-build prerequisites separately from native runtime availability.',
    'The human opens Google and completes all account/MFA actions. No automation attaches.',
    'Use regular-b or private for other manual roles; never reuse real browser profiles.',
    ...(artifact.engine === 'chromium'
      ? [
          'Append --workspace for the separate workspace configuration. Open it with the',
          'extension action button. Native browser tabs/security UI remain intact.',
          'Preserve --workspace when checking its private role; the component itself does',
          'not run in incognito windows. Engine-only and workspace profiles stay separate.',
        ]
      : ['This Brave reference stays unmodified; --workspace is not supported.']),
    '',
    'Optional local fixtures only (never Google account acceptance):',
    'npm ci --ignore-scripts --no-audit --no-fund',
    'npm test',
    `node mechanics.cjs --engine ${artifact.engine} --root ${root}${artifact.engine === 'chromium' ? ' --workspace' : ''}`,
    'The lockfile pins the small Playwright library set. No browser installation command',
    'or postinstall scripts are needed. Fixtures use separate disposable-purpose profiles',
    'and attach automation only to local test pages. Close them before manual acceptance.',
    '',
  ].join('\n');
}
async function assemble({ root: input, engine, platform, out }) {
  const { root, artifact, filename, integrity } = await fetchArtifact({
    root: input,
    engine,
    platform,
    fetch: false,
  });
  const destination = await assertContained(
    root,
    out ||
      path.join(root, 'output', `zacro-google-browser-compat-${engine}-${artifact.version}-${platform}.zip`),
  );
  if (path.extname(destination).toLowerCase() !== '.zip') throw new Error('Experiment output must be a ZIP.');
  await fs.mkdir(path.dirname(destination), { recursive: true });
  const entries = [];
  async function add(relative, required = false) {
    const source = path.join(toolkitRoot, relative);
    if (!(await exists(source))) {
      if (required) throw new Error(`Required experiment source missing: ${relative}`);
      return;
    }
    const stat = await fs.lstat(source);
    if (stat.isSymbolicLink()) throw new Error('Do not package linked source files.');
    if (stat.isDirectory())
      for (const name of (await fs.readdir(source)).sort()) await add(path.join(relative, name));
    else if (stat.isFile())
      entries.push({ name: `zacro-google-browser-compat/${relative.split(path.sep).join('/')}`, source });
  }
  for (const item of [
    'cli.cjs',
    'engines.lock.json',
    'lib',
    'build',
    'native-branding',
    'README.md',
    'docs/MANUAL-ACCEPTANCE.md',
    'record.cjs',
    'mechanics.cjs',
    'tests',
    'extension',
    'acceptance',
  ])
    await add(item, true);
  for (const item of ['docs']) {
    if (item === 'docs') {
      if (await exists(path.join(toolkitRoot, 'docs')))
        for (const name of await fs.readdir(path.join(toolkitRoot, 'docs')))
          if (name !== 'MANUAL-ACCEPTANCE.md' && name.endsWith('.md')) await add(path.join('docs', name));
    } else await add(item);
  }
  for (const filename of ['package.json', 'package-lock.json']) {
    const source = path.join(toolkitRoot, 'build', `kit-${filename}`);
    await assertRegularMarker(source);
    entries.push({ name: `zacro-google-browser-compat/${filename}`, source });
  }
  entries.push({ name: 'zacro-google-browser-compat/START-HERE.txt', data: kitStartInstructions(artifact) });
  entries.push({ name: `zacro-google-browser-compat/payload/${artifact.cacheName}`, source: filename });
  entries.push({
    name: 'zacro-google-browser-compat/bundle.json',
    data:
      JSON.stringify(
        {
          schemaVersion: 1,
          engine,
          platform,
          version: artifact.version,
          sourceRevision: artifact.sourceRevision,
          classification: artifact.classification,
          archiveSha256: integrity.sha256,
          nativeSourceBuild: false,
          liveGoogleAcceptance: 'untested',
          instructions: 'docs/MANUAL-ACCEPTANCE.md',
          entrypoint: 'START-HERE.txt',
          runtimeRequirements: { node: '>=24', npmInstallRequiredForManualLaunch: false },
          optionalFixtureDependencies: 'package-lock.json',
        },
        null,
        2,
      ) + '\n',
  });
  await writeStoredZip(destination, entries);
  return {
    destination,
    ...(await digests(destination)),
    upstreamArchiveSha256: integrity.sha256,
    sourceBuilt: false,
  };
}
module.exports = {
  getArtifactManifest,
  digests,
  validateArtifactURL,
  verifyArchive,
  fetchArtifact,
  inspectZip,
  safeArchiveName,
  treeIntegrity,
  prepareRuntime,
  writeStoredZip,
  kitStartInstructions,
  assemble,
};
