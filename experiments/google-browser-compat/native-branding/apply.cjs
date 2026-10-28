'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const execute = promisify(execFile);
const manifest = require('./manifest.json');
const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');

async function git(source, args) {
  return (
    await execute('git', ['-c', 'core.autocrlf=false', '-C', source, ...args], {
      windowsHide: true,
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    })
  ).stdout.trim();
}
function safeRelative(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    !value.includes('\\') &&
    !value.includes('\0') &&
    !path.posix.isAbsolute(value) &&
    !value.includes(':') &&
    value.split('/').every((part) => part && part !== '.' && part !== '..')
  );
}
async function verifiedPatch() {
  if (
    manifest.schemaVersion !== 1 ||
    !/^[a-f0-9]{40}$/.test(manifest.revision) ||
    !safeRelative(manifest.patch.path) ||
    !Array.isArray(manifest.files) ||
    !manifest.files.length ||
    new Set(manifest.files.map((file) => file.path)).size !== manifest.files.length
  )
    throw new Error('Invalid branding manifest.');
  for (const file of manifest.files) {
    if (
      !safeRelative(file.path) ||
      ![file.beforeSha256, file.afterSha256].every((digest) => /^[a-f0-9]{64}$/.test(digest))
    )
      throw new Error('Invalid branding source identity.');
  }
  const patchPath = path.join(__dirname, manifest.patch.path);
  const info = await fs.lstat(patchPath);
  if (
    !info.isFile() ||
    info.isSymbolicLink() ||
    sha256(await fs.readFile(patchPath)) !== manifest.patch.sha256
  )
    throw new Error('Branding patch digest mismatch.');
  return patchPath;
}
async function inspect({ source, requireRevision = true } = {}) {
  if (!source || !path.isAbsolute(source)) throw new Error('Pass an absolute Chromium source directory.');
  const sourceDirectory = await fs.realpath(source);
  const patchPath = await verifiedPatch();
  let observedRevision = null;
  if (requireRevision) {
    observedRevision = await git(sourceDirectory, ['rev-parse', 'HEAD']);
    if (observedRevision !== manifest.revision)
      throw new Error('Chromium HEAD does not match the native branding pin.');
    const top = await fs.realpath(await git(sourceDirectory, ['rev-parse', '--show-toplevel']));
    if (top !== sourceDirectory) throw new Error('Select the Chromium repository root, not a subdirectory.');
  }
  const files = [];
  for (const file of manifest.files) {
    const filename = path.join(sourceDirectory, file.path);
    const actual = await fs.realpath(filename);
    const relative = path.relative(sourceDirectory, actual);
    const info = await fs.lstat(filename);
    if (
      !info.isFile() ||
      info.isSymbolicLink() ||
      relative.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relative)
    )
      throw new Error(`Branding source is not a contained regular file: ${file.path}`);
    const digest = sha256(await fs.readFile(filename));
    const state =
      digest === file.beforeSha256 ? 'unpatched' : digest === file.afterSha256 ? 'patched' : 'modified';
    if (state === 'modified') throw new Error(`Source differs from both reviewed states: ${file.path}`);
    files.push({ path: file.path, sha256: digest, state });
  }
  if (new Set(files.map((file) => file.state)).size !== 1)
    throw new Error('Branding files are only partially patched; no changes were made.');
  const state = files[0].state;
  await git(sourceDirectory, ['apply', '--check', ...(state === 'patched' ? ['--reverse'] : []), patchPath]);
  return {
    schemaVersion: 1,
    sourceDirectory,
    expectedRevision: manifest.revision,
    observedRevision,
    revisionVerified: observedRevision === manifest.revision,
    state,
    patchSha256: manifest.patch.sha256,
    files,
    compiled: false,
    googleAcceptance: 'untested',
  };
}
async function apply({ source } = {}) {
  const before = await inspect({ source, requireRevision: true });
  if (before.state === 'patched') return { ...before, applied: false, alreadyApplied: true };
  await git(before.sourceDirectory, ['apply', '--whitespace=error', await verifiedPatch()]);
  const after = await inspect({ source: before.sourceDirectory, requireRevision: true });
  if (after.state !== 'patched') throw new Error('Patch application did not produce the reviewed output.');
  return { ...after, applied: true, alreadyApplied: false };
}
function options(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    if (value === '--source' && !result.source && argv[index + 1] && !argv[index + 1].startsWith('--'))
      result.source = argv[++index];
    else if (['--check', '--apply'].includes(value) && !result.operation) result.operation = value.slice(2);
    else throw new Error('Use --source ABS and exactly one of --check or --apply.');
  }
  if (!result.source || !result.operation)
    throw new Error('Use --source ABS and exactly one of --check or --apply.');
  return result;
}
async function main(argv = process.argv.slice(2)) {
  const { source, operation } = options(argv);
  return operation === 'apply' ? apply({ source }) : inspect({ source });
}
if (require.main === module)
  main()
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
module.exports = { manifest, inspect, apply, verifiedPatch, safeRelative, options, main };
