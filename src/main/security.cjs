'use strict';

const path = require('node:path');
const fs = require('node:fs/promises');

function webURL(value) {
  if (typeof value !== 'string' || value.length > 32768) return null;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
    return url.href;
  } catch {
    return null;
  }
}

function safeFilename(input, existingName = '') {
  if (typeof input !== 'string') throw new Error('A filename is required.');
  let name = input.normalize('NFKC').trim();
  if (
    !name ||
    name.length > 200 ||
    /[<>:"/\\|?*\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(name) ||
    /[. ]$/.test(name) ||
    /^\./.test(name)
  ) {
    throw new Error('Use a filename of 1–200 characters without path separators or reserved characters.');
  }
  if (/^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/i.test(name))
    throw new Error('This filename is reserved by the operating system.');
  const extension = path.extname(existingName);
  if (extension && path.extname(name).toLowerCase() !== extension.toLowerCase()) {
    if (!path.extname(name)) name += extension;
    else throw new Error(`Keep the original ${extension} file extension.`);
  }
  return name;
}

async function unusedPath(directory, filename) {
  const extension = path.extname(filename);
  const stem = path.basename(filename, extension);
  for (let index = 0; index < 10000; index++) {
    const candidate = path.join(directory, index ? `${stem} (${index})${extension}` : filename);
    try {
      await fs.access(candidate);
    } catch (error) {
      if (error.code === 'ENOENT') return candidate;
      throw error;
    }
  }
  throw new Error('Too many files have this name. Choose another filename.');
}

async function renameWithoutOverwrite(from, to) {
  if (from === to) return;
  // Unlike rename(), link() never overwrites a target on any supported OS.
  try {
    await fs.link(from, to);
  } catch (error) {
    if (!['EPERM', 'ENOTSUP', 'EXDEV', 'EOPNOTSUPP'].includes(error.code)) throw error;
    await fs.copyFile(from, to, require('node:fs').constants.COPYFILE_EXCL);
  }
  try {
    await fs.unlink(from);
  } catch (error) {
    await fs.unlink(to).catch(() => {});
    throw error;
  }
}

module.exports = { webURL, safeFilename, unusedPath, renameWithoutOverwrite };
