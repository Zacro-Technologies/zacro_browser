'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { adaptExtension } = require('../src/main/extensions/adapt.cjs');

test('worker resources reject ambiguous or foreign paths while accepting exactly one package root slash', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'zacro-worker-paths-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'source');
  await fs.mkdir(path.join(source, 'js'), { recursive: true });
  const script = "'use strict';\nimportScripts('./dependency.js');\n";
  await fs.writeFile(path.join(source, 'js/background.js'), script);
  await fs.writeFile(path.join(source, 'js/dependency.js'), 'globalThis.dependency = true;');
  const manifest = (service_worker) =>
    JSON.stringify({
      manifest_version: 3,
      name: 'Worker path boundary',
      version: '1',
      background: { service_worker },
    });
  const invalid = [
    '//js/background.js',
    '/js/../background.js',
    '/js/./background.js',
    '/js//background.js',
    '/js\\background.js',
    '/js/%2e%2e/background.js',
    '/js/background.js?query',
    '/js/background.js#fragment',
    'https://foreign.test/worker.js',
    'C:/worker.js',
    '/js/\u0001background.js',
    '/js/ background.js',
  ];
  let index = 0;
  for (const name of invalid) {
    await fs.writeFile(path.join(source, 'manifest.json'), manifest(name));
    await assert.rejects(
      adaptExtension(source, path.join(directory, `denied-${index++}`)),
      /Invalid worker entry path/,
      name,
    );
  }
  await fs.writeFile(path.join(source, 'manifest.json'), manifest('/js/background.js'));
  const adapted = await adaptExtension(source, path.join(directory, 'derived'));
  assert.equal(adapted.manifest.background.service_worker, '/js/background.js');
  assert.equal(await fs.readFile(path.join(source, 'js/background.js'), 'utf8'), script);
  assert.equal(await fs.readFile(path.join(source, 'manifest.json'), 'utf8'), manifest('/js/background.js'));
  assert.match(
    await fs.readFile(path.join(directory, 'derived/js/background.js'), 'utf8'),
    /^importScripts\("\.\.\/zacro-compat-bootstrap.js"\)/,
  );
  await fs.symlink(path.join(source, 'js/background.js'), path.join(source, 'escape'));
  await assert.rejects(adaptExtension(source, path.join(directory, 'symlink')), /Unsupported package entry/);
});
