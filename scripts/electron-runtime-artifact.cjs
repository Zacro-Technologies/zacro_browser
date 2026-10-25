'use strict';
// Local build provenance and content integrity. This is not a publisher
// signature or a substitute for native acceptance of the compiled runtime.
const fs = require('node:fs/promises');
const { createReadStream } = require('node:fs');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const build = require('../runtime/electron/build.json');
const { binaryTarget } = require('./platform-build.cjs');
const RECEIPT = 'zacro-runtime.json';
const sha = (data) => createHash('sha256').update(data).digest('hex');

async function runtimeIdentity() {
  const manifest = await require('./build-electron-runtime.cjs').series();
  return {
    electronVersion: build.electronVersion,
    electronCommit: build.electronCommit,
    chromiumCommit: build.chromiumCommit,
    patchesSha256: sha(JSON.stringify(manifest)),
  };
}

async function contents(directory) {
  const root = await fs.realpath(directory);
  const files = [];
  async function walk(relative) {
    for (const name of (await fs.readdir(path.join(root, relative))).sort()) {
      if (!relative && name === RECEIPT) continue;
      const entry = path.join(relative, name);
      const file = path.join(root, entry);
      const stat = await fs.lstat(file);
      const normalized = entry.split(path.sep).join('/');
      if (stat.isSymbolicLink()) {
        const target = await fs.readlink(file);
        const resolved = await fs.realpath(file);
        if (path.isAbsolute(target) || !resolved.startsWith(root + path.sep))
          throw new Error('Runtime symbolic link points outside artifact');
        files.push({ path: normalized, type: 'link', target });
      } else if (stat.isDirectory()) await walk(entry);
      else if (stat.isFile()) {
        const digest = createHash('sha256');
        for await (const chunk of createReadStream(file)) digest.update(chunk);
        files.push({
          path: normalized,
          type: 'file',
          size: stat.size,
          executable: stat.mode & 0o111,
          sha256: digest.digest('hex'),
        });
      } else throw new Error('Unsupported runtime file type');
    }
  }
  await walk('');
  return files;
}

async function expected(options) {
  if (!build.targets.includes(`${options.platform}-${options.arch}`))
    throw new Error('Unsupported runtime target');
  return {
    ...(options.identity || (await runtimeIdentity())),
    platform: options.platform,
    arch: options.arch,
  };
}

async function validateBinaries(directory, identity, files) {
  const main = identity.platform === 'darwin' ? 'Electron.app/Contents/MacOS/Electron' : 'electron.exe';
  async function check(relative, required = false) {
    const file = await fs.open(path.join(directory, relative), 'r');
    let header;
    try {
      if (!(await file.stat()).isFile()) throw new Error(`Invalid runtime binary: ${relative}`);
      const bytes = Buffer.alloc(4096);
      const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
      header = bytes.subarray(0, bytesRead);
    } finally {
      await file.close();
    }
    // Examine magic as well as conventional names: framework executables and
    // helpers may have no extension. Unsupported/fat native images also fail.
    const magic = header.toString('hex', 0, 4);
    const native =
      /^(?:cefaedfe|feedface|cffaedfe|feedfacf|cafebabe|bebafeca|cafebabf|bfbafeca|7f454c46)$/.test(magic) ||
      header.toString('ascii', 0, 2) === 'MZ';
    const nativePath =
      /\.(?:exe|dll|dylib|node|so(?:\.\d+)*)$/i.test(relative) ||
      /(?:^|\/)Contents\/MacOS\/[^/]+$/.test(relative) ||
      /(?:^|\/)([^/]+)\.framework\/(?:Versions\/[^/]+\/)?\1$/.test(relative);
    if (!required && !native && !nativePath) return;
    const target = binaryTarget(header);
    if (target?.platform !== identity.platform || target?.arch !== identity.arch)
      throw new Error(
        `Runtime binary target/architecture mismatch: ${relative} (expected ${identity.platform}/${identity.arch})`,
      );
  }
  // contents() has already checked every link's resolved containment. Inspect
  // the main through its real framework/bundle layout, including internal links.
  await check(main, true);
  for (const entry of files) if (entry.type === 'file' && entry.path !== main) await check(entry.path);
}

async function sealRuntime(directory, options) {
  const identity = await expected(options);
  if (
    (await fs.readFile(path.join(directory, 'version'), 'utf8')).trim().replace(/^v/, '') !==
    identity.electronVersion
  )
    throw new Error('Runtime version differs from pinned source identity');
  const files = await contents(directory);
  await validateBinaries(directory, identity, files);
  const receipt = { schemaVersion: 1, ...identity, files };
  await fs.writeFile(path.join(directory, RECEIPT), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  return receipt;
}

async function verifyRuntime(directory, options) {
  const identity = await expected(options);
  const receiptPath = path.join(directory, RECEIPT);
  const stat = await fs.lstat(receiptPath);
  if (!stat.isFile() || stat.size > 8 * 1024 * 1024) throw new Error('Invalid runtime receipt');
  const receipt = JSON.parse(await fs.readFile(receiptPath, 'utf8'));
  if (receipt.platform !== identity.platform || receipt.arch !== identity.arch)
    throw new Error('Runtime target mismatch');
  if (receipt.schemaVersion !== 1 || Object.keys(identity).some((key) => receipt[key] !== identity[key]))
    throw new Error('Runtime source identity mismatch');
  const files = await contents(directory);
  if (JSON.stringify(files) !== JSON.stringify(receipt.files))
    throw new Error('Runtime content integrity mismatch');
  await validateBinaries(directory, identity, files);
  return receipt;
}

async function installRuntime(artifact, options) {
  const destination = path.resolve(options.destination);
  const source = await fs.realpath(artifact);
  if (
    destination === source ||
    destination.startsWith(source + path.sep) ||
    source.startsWith(destination + path.sep)
  )
    throw new Error('Artifact and installation paths must not overlap');
  await verifyRuntime(source, options);
  const parent = path.dirname(destination);
  await fs.mkdir(parent, { recursive: true });
  const stage = path.join(parent, '.zacro-runtime-stage-' + randomUUID());
  const backup = path.join(parent, '.zacro-runtime-backup-' + randomUUID());
  let saved = false;
  try {
    await fs.cp(source, stage, {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
      preserveTimestamps: true,
    });
    // Re-read staged bytes, catching mutation between source verification/copy.
    await verifyRuntime(stage, options);
    try {
      await fs.rename(destination, backup);
      saved = true;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    try {
      await fs.rename(stage, destination);
    } catch (error) {
      if (saved) await fs.rename(backup, destination);
      throw error;
    }
    return { destination, backup: saved ? backup : null };
  } finally {
    await fs.rm(stage, { recursive: true, force: true });
  }
}

if (require.main === module) {
  const [command, directory] = process.argv.slice(2);
  const options = { platform: process.platform, arch: process.arch };
  const operation =
    command === 'seal'
      ? sealRuntime
      : command === 'verify'
        ? verifyRuntime
        : command === 'install'
          ? installRuntime
          : null;
  if (!operation || !directory) {
    console.error('Usage: node scripts/electron-runtime-artifact.cjs seal|verify|install DIST_DIRECTORY');
    process.exitCode = 1;
  } else {
    if (command === 'install')
      options.destination = path.join(path.dirname(require.resolve('electron/package.json')), 'dist');
    operation(directory, options)
      .then((result) =>
        console.log(
          command === 'install'
            ? JSON.stringify(result)
            : `Runtime ${command} passed: ${result.platform}/${result.arch}`,
        ),
      )
      .catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
      });
  }
}
module.exports = { runtimeIdentity, sealRuntime, verifyRuntime, installRuntime };
