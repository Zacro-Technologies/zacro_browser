'use strict';
const fs = require('node:fs/promises');
const syncFs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const ROOT_MARKER = '.zacro-google-prototype.json';
const PROFILE_MARKER = '.zacro-profile-owner.json';
const KIND = 'zacro-google-browser-compat';
const toolkitRoot = path.resolve(__dirname, '..');

function findRepository() {
  let directory = toolkitRoot;
  while (path.dirname(directory) !== directory) {
    try {
      const metadata = JSON.parse(syncFs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
      if (metadata.name === 'zacro-browser' && syncFs.existsSync(path.join(directory, 'src/main/main.cjs')))
        return directory;
    } catch {}
    directory = path.dirname(directory);
  }
  return null;
}
const repositoryRoot = findRepository();
const normalize = (value) =>
  process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
function inside(parent, child) {
  const relative = path.relative(normalize(parent), normalize(child));
  return (
    relative === '' ||
    (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))
  );
}
function resolveRoot(input) {
  const selected =
    input ||
    (process.platform === 'win32'
      ? 'C:\\zacro-google-prototype'
      : path.join(os.homedir(), 'zacro-google-prototype'));
  if (!path.isAbsolute(selected)) throw new Error('The experiment root must be an absolute path.');
  const root = path.resolve(selected);
  if (root === path.parse(root).root || normalize(root) === normalize(os.homedir()))
    throw new Error('Use a dedicated experiment directory, not a volume root or home directory.');
  if (repositoryRoot && (inside(repositoryRoot, root) || inside(root, repositoryRoot)))
    throw new Error('Experiment caches, outputs and profiles must be outside the application repository.');
  return root;
}
async function nearestRealPath(value) {
  let directory = path.resolve(value);
  const tail = [];
  while (true) {
    try {
      return path.join(await fs.realpath(directory), ...tail.reverse());
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const parent = path.dirname(directory);
      if (parent === directory) throw error;
      tail.push(path.basename(directory));
      directory = parent;
    }
  }
}
async function assertContained(root, target) {
  if (!inside(root, target)) throw new Error('Path escapes the owned experiment root.');
  const [realRoot, realTarget] = await Promise.all([nearestRealPath(root), nearestRealPath(target)]);
  if (!inside(realRoot, realTarget))
    throw new Error('A link redirects the path outside the experiment root.');
  if (repositoryRoot) {
    const realRepository = await nearestRealPath(repositoryRoot);
    if (inside(realRepository, realTarget)) throw new Error('Path resolves into the application repository.');
  }
  return path.resolve(target);
}
async function readJSON(filename) {
  return JSON.parse(await fs.readFile(filename, 'utf8'));
}
async function assertRegularMarker(filename) {
  const info = await fs.lstat(filename);
  if (!info.isFile() || info.isSymbolicLink())
    throw new Error('Owner and runtime markers must be ordinary files.');
}
async function ensureRoot(input, { create = true } = {}) {
  const root = resolveRoot(input);
  const real = await nearestRealPath(root);
  if (repositoryRoot) {
    const repository = await nearestRealPath(repositoryRoot);
    if (inside(repository, real) || inside(real, repository))
      throw new Error('Linked root overlaps the repository.');
  }
  let entries;
  try {
    entries = await fs.readdir(root);
  } catch (error) {
    if (error.code !== 'ENOENT' || !create) throw error;
    await fs.mkdir(root, { recursive: true });
    entries = [];
  }
  const marker = path.join(root, ROOT_MARKER);
  if (!entries.includes(ROOT_MARKER)) {
    if (!create || entries.length)
      throw new Error('Refusing to adopt an existing nonempty directory without an experiment owner marker.');
    await fs.writeFile(marker, JSON.stringify({ schemaVersion: 1, kind: KIND, root }, null, 2) + '\n', {
      flag: 'wx',
    });
  }
  await assertRegularMarker(marker);
  const owner = await readJSON(marker);
  if (owner.schemaVersion !== 1 || owner.kind !== KIND || normalize(owner.root || '') !== normalize(root))
    throw new Error('Experiment root owner marker does not match.');
  return root;
}
function configurationFor(engine, workspace) {
  if (!['chromium', 'brave'].includes(engine)) throw new Error('Unknown engine.');
  if (workspace && engine !== 'chromium') throw new Error('The Brave reference must remain unmodified.');
  return engine === 'brave' ? 'reference' : workspace ? 'workspace' : 'engine-only';
}
async function ensureManualProfile({ root: input, engine, platform, role, workspace = false }) {
  if (!['regular-a', 'regular-b', 'private'].includes(role))
    throw new Error('Select regular-a, regular-b or private.');
  if (!['win32-x64', 'darwin-arm64'].includes(platform)) throw new Error('Unsupported experiment platform.');
  const configuration = configurationFor(engine, workspace);
  const root = await ensureRoot(input);
  const directory = await assertContained(
    root,
    path.join(root, 'profiles', engine, platform, configuration, role),
  );
  await fs.mkdir(directory, { recursive: true });
  const expected = {
    schemaVersion: 1,
    kind: KIND,
    purpose: 'manual-acceptance',
    engine,
    platform,
    configuration,
    role,
  };
  const marker = path.join(directory, PROFILE_MARKER);
  const entries = await fs.readdir(directory);
  if (!entries.includes(PROFILE_MARKER)) {
    if (entries.length) throw new Error('Refusing to adopt a pre-existing browser profile.');
    await fs.writeFile(marker, JSON.stringify(expected, null, 2) + '\n', { flag: 'wx' });
  }
  await assertRegularMarker(marker);
  const actual = await readJSON(marker);
  if (Object.entries(expected).some(([key, value]) => actual[key] !== value))
    throw new Error('Profile belongs to another experiment configuration or purpose.');
  return { directory, configuration, marker };
}
module.exports = {
  ROOT_MARKER,
  PROFILE_MARKER,
  KIND,
  toolkitRoot,
  repositoryRoot,
  inside,
  resolveRoot,
  nearestRealPath,
  assertContained,
  ensureRoot,
  ensureManualProfile,
  configurationFor,
  readJSON,
  assertRegularMarker,
};
