'use strict';

// Fetch only the nine pinned original files needed to validate the branding
// patch. This is neither a Chromium checkout nor a compiled browser.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { setTimeout: wait } = require('node:timers/promises');
const manifest = require('./manifest.json');
const { ensureRoot, assertContained, assertRegularMarker } = require('../lib/paths.cjs');
const MARKER = '.zacro-native-references.json';
const MAX_FILE_BYTES = 2 * 1024 ** 2;
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function parseOptions(argv) {
  if (argv.length !== 2 || argv[0] !== '--root' || !path.isAbsolute(argv[1]))
    throw new Error('Use --root ABSOLUTE_EXTERNAL_EXPERIMENT_DIRECTORY.');
  return { root: argv[1] };
}

function verifyManifest() {
  if (
    manifest.schemaVersion !== 1 ||
    !/^[a-f0-9]{40}$/.test(manifest.revision) ||
    manifest.files.length !== 9
  )
    throw new Error('Expected the reviewed nine-file native branding manifest.');
  const seen = new Set();
  for (const file of manifest.files) {
    if (
      !/^[a-zA-Z0-9._/-]+$/.test(file.path) ||
      file.path.split('/').some((part) => !part || part === '.' || part === '..') ||
      seen.has(file.path.toLowerCase()) ||
      !/^[a-f0-9]{64}$/.test(file.beforeSha256) ||
      file.sourceUrl !==
        `https://raw.githubusercontent.com/chromium/chromium/${manifest.revision}/${file.path}`
    )
      throw new Error('Reference paths, hashes and upstream URLs must match the pinned source revision.');
    seen.add(file.path.toLowerCase());
  }
}

async function checkedPath(root, target) {
  await assertContained(root, target);
  let current = root;
  const parts = path.relative(root, target).split(path.sep).filter(Boolean);
  for (const part of [null, ...parts]) {
    if (part !== null) current = path.join(current, part);
    try {
      if ((await fs.lstat(current)).isSymbolicLink())
        throw new Error('Reference paths cannot traverse symbolic links or junctions.');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return target;
}

async function existingFile(root, directory, file) {
  const target = await checkedPath(root, path.join(directory, file.path));
  let info;
  try {
    info = await fs.lstat(target);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_FILE_BYTES)
    throw new Error(`Reference must be an ordinary bounded file: ${file.path}`);
  const bytes = await fs.readFile(target);
  if (sha256(bytes) !== file.beforeSha256)
    throw new Error(`Existing reference differs from its pinned SHA-256; retained: ${file.path}`);
  return { path: file.path, sha256: file.beforeSha256, bytes: bytes.length };
}

function retryDelay(header, now = Date.now()) {
  if (!header) return 10000;
  const seconds = /^\d+$/.test(header) ? Number(header) : (Date.parse(header) - now) / 1000;
  if (!Number.isFinite(seconds)) return 10000;
  // Do not retry earlier than the provider permits. A longer wait leaves this
  // origin unavailable for this invocation instead of ignoring Retry-After.
  return seconds > 60 ? null : Math.max(1000, Math.ceil(seconds * 1000));
}

async function download(file) {
  const sources = [
    { url: file.sourceUrl, base64: false },
    {
      url: `https://chromium.googlesource.com/chromium/src/+/${manifest.revision}/${file.path}?format=TEXT`,
      base64: true,
    },
  ];
  let lastStatus;
  for (const source of sources) {
    // At most two requests per origin. A canonical upstream fallback is used
    // only for transient HTTP failures, never to accept an integrity mismatch.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const response = await fetch(source.url, {
        redirect: 'error',
        credentials: 'omit',
        signal: AbortSignal.timeout(30000),
      });
      if (response.url && response.url !== source.url)
        throw new Error(`Pinned source redirected unexpectedly: ${file.path}`);
      if (!response.ok) {
        await response.body?.cancel();
        lastStatus = response.status;
        if (![429, 502, 503, 504].includes(response.status))
          throw new Error(`Pinned source request failed: ${file.path} (${response.status}).`);
        const delay = retryDelay(response.headers.get('retry-after'));
        if (attempt === 1 || delay === null) break;
        await wait(delay);
        continue;
      }
      const limit = source.base64 ? Math.ceil(MAX_FILE_BYTES / 3) * 4 + 16 : MAX_FILE_BYTES;
      if (Number(response.headers.get('content-length')) > limit || !response.body) {
        await response.body?.cancel();
        throw new Error(`Reference exceeds its download limit: ${file.path}`);
      }
      const chunks = [];
      let length = 0;
      for await (const chunk of response.body) {
        length += chunk.length;
        if (length > limit) throw new Error(`Reference exceeds its download limit: ${file.path}`);
        chunks.push(Buffer.from(chunk));
      }
      let bytes = Buffer.concat(chunks);
      if (source.base64) {
        const encoded = bytes.toString('ascii').trim();
        if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))
          throw new Error(`Invalid canonical source encoding: ${file.path}`);
        bytes = Buffer.from(encoded, 'base64');
      }
      if (bytes.length > MAX_FILE_BYTES || sha256(bytes) !== file.beforeSha256)
        throw new Error(`Downloaded reference failed its pinned SHA-256: ${file.path}`);
      return bytes;
    }
  }
  throw new Error(`Pinned source request failed after bounded retries: ${file.path} (${lastStatus}).`);
}

async function fetchReferences(input) {
  if (!input || !path.isAbsolute(input)) throw new Error('Use an absolute external experiment root.');
  verifyManifest();
  await checkedPath(path.resolve(input), path.resolve(input));
  const root = await ensureRoot(input);
  const directory = await checkedPath(
    root,
    path.join(root, 'source-references', `native-${manifest.revision}`),
  );
  await fs.mkdir(directory, { recursive: true });
  const marker = await checkedPath(root, path.join(directory, MARKER));
  const expected = {
    schemaVersion: 1,
    kind: 'zacro-native-branding-references',
    sourceRevision: manifest.revision,
    files: manifest.files.map((file) => ({ path: file.path, sha256: file.beforeSha256 })),
  };
  const entries = await fs.readdir(directory);
  if (!entries.includes(MARKER)) {
    if (entries.length)
      throw new Error('Refusing to adopt a nonempty reference directory without its owner marker.');
    await fs.writeFile(marker, JSON.stringify(expected, null, 2) + '\n', { flag: 'wx' });
  }
  await assertRegularMarker(marker);
  const actual = JSON.parse(await fs.readFile(marker, 'utf8'));
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error('Native reference owner marker or pinned file identities do not match.');

  // Verify all cached entries before any network or publication work begins.
  const results = [];
  for (const file of manifest.files) results.push(await existingFile(root, directory, file));
  let downloadedFiles = 0;
  for (let index = 0; index < manifest.files.length; index += 1) {
    if (results[index]) continue;
    const file = manifest.files[index];
    const bytes = await download(file);
    const target = await checkedPath(root, path.join(directory, file.path));
    await fs.mkdir(path.dirname(target), { recursive: true });
    await checkedPath(root, target);
    const temporary = await checkedPath(
      root,
      path.join(path.dirname(target), `.zacro-reference-${randomUUID()}.part`),
    );
    await fs.writeFile(temporary, bytes, { flag: 'wx', mode: 0o644 });
    try {
      // A same-directory hard link publishes atomically without rename's
      // overwrite semantics. A concurrently created destination is retained.
      await checkedPath(root, target);
      await fs.link(temporary, target);
    } finally {
      await fs.unlink(temporary);
    }
    results[index] = await existingFile(root, directory, file);
    downloadedFiles += 1;
  }
  return {
    schemaVersion: 1,
    sourceRevision: manifest.revision,
    referenceDirectory: directory,
    verifiedFiles: results.length,
    downloadedFiles,
    files: results,
    fullCheckout: false,
    compiled: false,
  };
}

if (require.main === module)
  Promise.resolve()
    .then(() => fetchReferences(parseOptions(process.argv.slice(2)).root))
    .then((result) => process.stdout.write(JSON.stringify(result, null, 2) + '\n'))
    .catch((error) => {
      process.stderr.write(error.message + '\n');
      process.exitCode = 1;
    });

module.exports = { fetchReferences, parseOptions, verifyManifest, retryDelay };
