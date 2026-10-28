'use strict';

// Inventory only: no processes, profile access, or executable evaluation.
const fs = require('node:fs/promises');
const path = require('node:path');
const { digests } = require('../lib/artifacts.cjs');
const { assertContained, inside } = require('../lib/paths.cjs');

const order = (left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0);

async function ordinaryRoot(directory) {
  if (!path.isAbsolute(directory)) throw new Error('Runtime inventory requires an absolute directory.');
  const info = await fs.lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink())
    throw new Error('Runtime inventory root must be an ordinary directory.');
  await assertContained(directory, directory);
}

function windowsRelative(line) {
  if (
    !line ||
    line !== line.trim() ||
    /[\0\r\n:]/u.test(line) ||
    path.posix.isAbsolute(line) ||
    path.win32.isAbsolute(line)
  )
    throw new Error('GN runtime dependencies must be relative paths inside the build output.');
  // GN data directories may carry a trailing slash.
  const parts = line.replace(/[\\/]+$/u, '').split(/[\\/]/u);
  if (
    parts.some(
      (part) =>
        !part ||
        part === '..' ||
        (part !== '.' &&
          (/[<>"|?*]/u.test(part) ||
            part.endsWith('.') ||
            part.trimEnd() !== part ||
            /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/iu.test(part))),
    )
  )
    throw new Error('GN runtime dependency has an unsafe Windows path.');
  const normalized = parts.filter((part) => part !== '.').join('/');
  if (!normalized) throw new Error('GN runtime dependency cannot select the entire build directory.');
  return normalized;
}

async function windowsInventory(out, dependenciesText) {
  await ordinaryRoot(out);
  if (typeof dependenciesText !== 'string') throw new Error('GN runtime dependency output must be text.');
  const collected = new Map();
  const identities = new Map();

  async function visit(relative) {
    // Check every ancestor too: a directly listed link/child must not bypass
    // the link rejection applied during a normal recursive directory walk.
    let filename = out;
    const parts = relative.split('/');
    let info;
    for (let index = 0; index < parts.length; index++) {
      filename = path.join(filename, parts[index]);
      await assertContained(out, filename);
      info = await fs.lstat(filename);
      if (info.isSymbolicLink()) throw new Error('Windows runtime dependencies must not contain links.');
      if (index < parts.length - 1 && !info.isDirectory()) throw new Error('Invalid runtime ancestor.');
    }
    if (info.isDirectory()) {
      for (const name of (await fs.readdir(filename)).sort())
        await visit(windowsRelative(`${relative}/${name}`));
    } else if (info.isFile()) {
      const identity = relative.toLowerCase();
      const previous = identities.get(identity);
      if (previous && previous !== relative) throw new Error('Case-colliding Windows runtime paths.');
      identities.set(identity, relative);
      if (!collected.has(relative))
        collected.set(relative, { path: relative, sha256: (await digests(filename)).sha256 });
    } else throw new Error('Unexpected Windows runtime filesystem entry.');
  }

  for (const line of dependenciesText.split(/\r?\n/u)) {
    if (!line.trim()) continue;
    await visit(windowsRelative(line));
  }
  if (!collected.has('chrome.exe')) throw new Error('Final chrome.exe missing from GN runtime dependencies.');
  return [...collected.values()].sort(order);
}

async function macInventory(bundle) {
  await ordinaryRoot(bundle);
  const realBundle = await fs.realpath(bundle);
  const entries = [];

  async function visit(relative = '') {
    const filename = path.join(bundle, ...relative.split('/').filter(Boolean));
    const info = await fs.lstat(filename);
    const key = relative ? `Zacro Prototype.app/${relative}` : 'Zacro Prototype.app';
    const mode = info.mode & 0o7777;
    if (info.isSymbolicLink()) {
      const link = await fs.readlink(filename);
      if (
        !link ||
        /[\0\\]/u.test(link) ||
        /^[a-z]:/iu.test(link) ||
        path.posix.isAbsolute(link) ||
        path.win32.isAbsolute(link)
      )
        throw new Error('Mac runtime links must have relative targets.');
      // realpath verifies the whole chain, catches dangling/cyclic links and
      // resolves .. after symlink expansion with filesystem semantics.
      const resolved = await fs.realpath(filename);
      if (!inside(realBundle, resolved)) throw new Error('Mac runtime link escapes its app bundle.');
      entries.push({ path: key, type: 'symlink', mode, link });
    } else if (info.isDirectory()) {
      entries.push({ path: key, type: 'directory', mode });
      for (const name of (await fs.readdir(filename)).sort())
        await visit(relative ? `${relative}/${name}` : name);
    } else if (info.isFile()) {
      entries.push({ path: key, type: 'file', mode, sha256: (await digests(filename)).sha256 });
    } else throw new Error('Unexpected Mac runtime filesystem entry.');
  }

  await visit();
  return entries.sort(order);
}

module.exports = { windowsInventory, macInventory };
