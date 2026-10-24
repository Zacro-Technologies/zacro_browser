'use strict';
// Original MIT-licensed package transformation. The source remains immutable;
// callers retain the verified archive and provenance separately from this copy.
const fs = require('node:fs/promises');
const path = require('node:path');
const TRANSFORM_VERSION = 1;
const BOOTSTRAP = 'zacro-compat-bootstrap.js';

async function adaptExtension(source, destination, { publicKey } = {}) {
  source = path.resolve(source);
  destination = path.resolve(destination);
  if (destination === source || destination.startsWith(source + path.sep))
    throw new Error('Derived copy must be outside the source');
  const manifest = JSON.parse(await fs.readFile(path.join(source, 'manifest.json'), 'utf8'));
  for (const reserved of [BOOTSTRAP, 'zacro-compat-transport.html'])
    if (
      await fs.access(path.join(source, reserved)).then(
        () => true,
        () => false,
      )
    )
      throw new Error('Reserved compatibility bootstrap path');
  // Validated package acquisition is a separate boundary, but do not follow links.
  for (const name of await fs.readdir(source, { recursive: true })) {
    const stat = await fs.lstat(path.join(source, name));
    if (!stat.isFile() && !stat.isDirectory()) throw new Error('Unsupported package entry');
  }
  await fs.mkdir(destination);
  for (const name of await fs.readdir(source))
    await fs.cp(path.join(source, name), path.join(destination, name), {
      recursive: true,
      errorOnExist: true,
      force: false,
    });
  await fs.copyFile(path.join(__dirname, 'bootstrap.js'), path.join(destination, BOOTSTRAP));
  await fs.writeFile(
    path.join(destination, 'zacro-compat-transport.html'),
    '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>\n',
  );
  if (publicKey) manifest.key = publicKey;
  for (const entry of manifest.content_scripts || []) {
    if (entry.world !== 'MAIN' && entry.js?.length) entry.js = [BOOTSTRAP, ...entry.js];
  }
  const background = manifest.background;
  if (background?.service_worker) {
    const name = background.service_worker;
    if (path.isAbsolute(name) || name.split(/[\\/]/).includes('..'))
      throw new Error('Invalid worker entry path');
    const filename = path.join(destination, name);
    const relative = path.posix.relative(path.posix.dirname(name), BOOTSTRAP);
    const specifier = relative.startsWith('.') ? relative : './' + relative;
    const prefix =
      background.type === 'module'
        ? `import ${JSON.stringify(specifier)};\n`
        : `importScripts(${JSON.stringify(specifier)});\n`;
    await fs.writeFile(filename, prefix + (await fs.readFile(filename, 'utf8')));
  } else if (background?.scripts) {
    background.scripts = [BOOTSTRAP, ...background.scripts];
  } else if (background?.page) {
    const name = background.page;
    if (path.isAbsolute(name) || name.split(/[\\/]/).includes('..'))
      throw new Error('Invalid background entry path');
    const filename = path.join(destination, name);
    const html = await fs.readFile(filename, 'utf8');
    const tags = /<!--[\s\S]*?-->|<\/?[a-zA-Z][^>"']*(?:(?:"[^"]*"|'[^']*')[^>"']*)*>/g;
    let position = html.length;
    for (const token of html.matchAll(tags))
      if (/^<script\b/i.test(token[0]) || /^<\/head\s*>/i.test(token[0])) {
        position = token.index;
        break;
      }
    await fs.writeFile(
      filename,
      html.slice(0, position) + '<script src="/zacro-compat-bootstrap.js"></script>' + html.slice(position),
    );
  }
  await fs.writeFile(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return { manifest, transformVersion: TRANSFORM_VERSION };
}
module.exports = { adaptExtension };
