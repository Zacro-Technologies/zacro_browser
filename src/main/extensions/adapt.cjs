'use strict';
// Original MIT-licensed package transformation. The source remains immutable;
// callers retain the verified archive and provenance separately from this copy.
const fs = require('node:fs/promises');
const path = require('node:path');
const { parse } = require('parse5');
const { inspectManifest } = require('./catalog.cjs');
const TRANSFORM_VERSION = 3;
const BOOTSTRAP = 'zacro-compat-bootstrap.js';

async function adaptExtension(source, destination, { publicKey } = {}) {
  source = path.resolve(source);
  destination = path.resolve(destination);
  if (destination === source || destination.startsWith(source + path.sep))
    throw new Error('Derived copy must be outside the source');
  const manifest = JSON.parse(await fs.readFile(path.join(source, 'manifest.json'), 'utf8'));
  inspectManifest(manifest);
  if (manifest.devtools_page) {
    const resource = path.join(source, manifest.devtools_page);
    const stat = await fs.lstat(resource).catch(() => null);
    const real = await fs.realpath(resource).catch(() => null);
    if (!stat?.isFile() || !real?.startsWith((await fs.realpath(source)) + path.sep))
      throw new Error('Invalid devtools_page resource');
  }
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
    if (background.type === 'module') {
      await fs.writeFile(
        filename,
        `import ${JSON.stringify(specifier)};\n` + (await fs.readFile(filename, 'utf8')),
      );
    } else {
      // A separate Script keeps the original directive prologue. Both files
      // remain in the entry's directory, so native importScripts resolution and
      // the ServiceWorkerGlobalScope URL are unchanged.
      const companion = 'zacro-compat-original-' + path.basename(name);
      const companionPath = path.join(path.dirname(filename), companion);
      if (
        await fs.access(companionPath).then(
          () => true,
          () => false,
        )
      )
        throw new Error('Reserved classic worker companion path');
      await fs.copyFile(filename, companionPath);
      await fs.writeFile(
        filename,
        `importScripts(${JSON.stringify(specifier)});\nimportScripts(${JSON.stringify('./' + companion)});\n`,
      );
    }
  } else if (background?.scripts) {
    background.scripts = [BOOTSTRAP, ...background.scripts];
  } else if (background?.page) {
    const name = background.page;
    if (path.isAbsolute(name) || name.split(/[\\/]/).includes('..'))
      throw new Error('Invalid background entry path');
    const filename = path.join(destination, name);
    const html = await fs.readFile(filename, 'utf8');
    const document = parse(html, { sourceCodeLocationInfo: true });
    const scripts = [];
    let head, body;
    const visit = (node, foreignRoot) => {
      if (node.tagName === 'head') head = node;
      if (node.tagName === 'body') body = node;
      if (node.namespaceURI && node.namespaceURI !== 'http://www.w3.org/1999/xhtml' && !foreignRoot)
        foreignRoot = node;
      if (node.tagName === 'script') scripts.push((foreignRoot || node).sourceCodeLocation?.startOffset);
      // Template contents are inert DocumentFragments, not childNodes. Deliberately
      // do not traverse node.content; raw-text elements are handled by the parser.
      for (const child of node.childNodes || []) visit(child, foreignRoot);
    };
    visit(document);
    const positions = scripts.filter(Number.isInteger);
    const position = positions.length
      ? Math.min(...positions)
      : (head?.sourceCodeLocation?.endTag?.startOffset ?? body?.sourceCodeLocation?.startTag?.endOffset);
    if (!Number.isInteger(position)) throw new Error('Background HTML has no safe bootstrap insertion point');
    await fs.writeFile(
      filename,
      html.slice(0, position) + '<script src="/zacro-compat-bootstrap.js"></script>' + html.slice(position),
    );
  }
  // Extension documents have the same facade before their first executable
  // script. Include ordinary popup/options and nested HTML resources, not only
  // the manifest's initial view; original bytes outside insertion stay intact.
  for (const name of await fs.readdir(destination, { recursive: true })) {
    if (!/\.html?$/i.test(name) || name === 'zacro-compat-transport.html' || name === background?.page)
      continue;
    const filename = path.join(destination, name);
    if (!(await fs.stat(filename)).isFile()) continue;
    const html = await fs.readFile(filename, 'utf8'),
      document = parse(html, { sourceCodeLocationInfo: true });
    let position;
    const visit = (node) => {
      if (node.tagName === 'script' && Number.isInteger(node.sourceCodeLocation?.startOffset))
        position = Math.min(position ?? Infinity, node.sourceCodeLocation.startOffset);
      for (const child of node.childNodes || []) visit(child);
    };
    visit(document);
    if (!Number.isInteger(position))
      position =
        document.childNodes.find((node) => node.nodeName === '#documentType')?.sourceCodeLocation
          ?.endOffset || 0;
    await fs.writeFile(
      filename,
      html.slice(0, position) + '<script src="/zacro-compat-bootstrap.js"></script>' + html.slice(position),
    );
  }
  await fs.writeFile(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return { manifest, transformVersion: TRANSFORM_VERSION };
}
module.exports = { adaptExtension };
