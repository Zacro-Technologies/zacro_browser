'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { deflateSync } = require('node:zlib');
const { BrowserStore } = require('../src/core/store.cjs');
const { createInteractiveSite } = require('../test/fixtures/interactive-site.cjs');
const { createShowcaseState } = require('../test/fixtures/showcase-state.cjs');
const { packagedPaths } = require('./platform-build.cjs');

const demoFavorites = [
  { id: 'mail', title: 'Mail', color: '#4b8de7', heading: 'A little space for your inbox.' },
  { id: 'calendar', title: 'Calendar', color: '#ec6b69', heading: 'Make room for the day ahead.' },
  { id: 'notes', title: 'Notes', color: '#d4a348', heading: 'Keep a thought close by.' },
  { id: 'studio', title: 'Studio', color: '#8870c7', heading: 'A place for work in progress.' },
];

// Original fixture icons, rendered from simple vector shapes into bounded PNGs.
// No external assets, additional runtime or browser-security exceptions needed.
function demoIcon(id) {
  const size = 32;
  const rgb = (hex) => [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16));
  const rect =
    (x, y, width, height, radius = 0) =>
    (px, py) => {
      const dx = Math.max(x + radius - px, 0, px - (x + width - radius));
      const dy = Math.max(y + radius - py, 0, py - (y + height - radius));
      return (
        px >= x && px <= x + width && py >= y && py <= y + height && dx * dx + dy * dy <= radius * radius
      );
    };
  const line = (x1, y1, x2, y2, width) => (x, y) => {
    const dx = x2 - x1,
      dy = y2 - y1;
    const t = Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(x - x1 - t * dx, y - y1 - t * dy) <= width / 2;
  };
  const color = demoFavorites.find((item) => item.id === id).color;
  const shapes = [[rect(1, 1, 30, 30, 7), color]];
  if (id === 'mail')
    shapes.push(
      [rect(6, 9, 20, 15, 2), '#ffffff'],
      [line(7, 11, 16, 17, 1.5), color],
      [line(16, 17, 25, 11, 1.5), color],
    );
  else if (id === 'calendar') {
    shapes.push([rect(6, 7, 20, 20, 3), '#ffffff'], [rect(6, 7, 20, 6, 2), '#f1c0b9']);
    for (const x of [10, 16, 22])
      for (const y of [17, 22]) shapes.push([rect(x - 1.25, y - 1.25, 2.5, 2.5, 0.5), '#635d68']);
    shapes.push([line(11, 6, 11, 10, 2), '#ffffff'], [line(21, 6, 21, 10, 2), '#ffffff']);
  } else if (id === 'notes') {
    shapes.push([rect(7, 5, 18, 23, 2), '#fffbee']);
    for (const y of [12, 17, 22]) shapes.push([line(11, y, 21, y, 1.6), '#b99857']);
  } else
    shapes.push(
      [rect(6, 6, 20, 20, 3), '#ffffff'],
      [rect(9, 9, 6, 14, 1), '#b4a5dc'],
      [rect(17, 9, 6, 6, 1), '#8870c7'],
      [rect(17, 17, 6, 6, 1), '#d8c9ed'],
    );
  const layers = shapes.map(([contains, value]) => ({ contains, color: rgb(value) }));
  const pixels = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++) {
      const sum = [0, 0, 0];
      let coverage = 0;
      for (let sy = 0; sy < 4; sy++)
        for (let sx = 0; sx < 4; sx++) {
          const px = x + (sx + 0.5) / 4,
            py = y + (sy + 0.5) / 4;
          const layer = layers.findLast((item) => item.contains(px, py));
          if (!layer) continue;
          coverage++;
          layer.color.forEach((value, channel) => (sum[channel] += value));
        }
      const offset = y * (size * 4 + 1) + 1 + x * 4;
      for (let channel = 0; channel < 3; channel++)
        pixels[offset + channel] = coverage ? Math.round(sum[channel] / coverage) : 0;
      pixels[offset + 3] = Math.round((coverage * 255) / 16);
    }
  const chunk = (name, data) => {
    const type = Buffer.from(name, 'ascii');
    let crc = 0xffffffff;
    for (const byte of Buffer.concat([type, data])) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    const header = Buffer.alloc(4),
      trailer = Buffer.alloc(4);
    header.writeUInt32BE(data.length);
    trailer.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([header, type, data, trailer]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(pixels)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function createShowcaseSite() {
  const server = createInteractiveSite();
  const original = server.listeners('request')[0];
  const icons = new Map(demoFavorites.map((item) => [item.id, demoIcon(item.id)]));
  server.removeListener('request', original);
  server.on('request', (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const match = /^\/showcase\/(mail|calendar|notes|studio)(\.png)?$/.exec(url.pathname);
    if (!match) return original(request, response);
    const [, id, image] = match;
    if (image) {
      response.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=3600' });
      return response.end(icons.get(id));
    }
    const demo = demoFavorites.find((item) => item.id === id);
    const end = response.end.bind(response);
    response.end = (body, ...args) => {
      if (typeof body === 'string')
        body = body
          .replace(
            '<link rel="icon" href="/favicon.ico">',
            `<link rel="icon" type="image/png" href="/showcase/${id}.png">`,
          )
          .replace(/<title>[^<]*<\/title>/, `<title>${demo.title} — Local demo</title>`)
          .replace(/<h1>[^<]*<\/h1>/, `<h1>${demo.heading}</h1>`)
          .replace(
            'Issue 001 · A little room to think',
            `Local ${demo.title.toLowerCase()} demo · No account connected`,
          );
      return end(body, ...args);
    };
    request.url = id === 'notes' ? '/notes' : '/';
    return original(request, response);
  });
  return server;
}

function populateLocalFavorites(state, localUrl) {
  state.tabs
    .filter((tab) => tab.pinned)
    .slice(0, demoFavorites.length)
    .forEach((tab, index) => {
      const demo = demoFavorites[index];
      tab.title = tab.customTitle = demo.title;
      tab.url = new URL(`/showcase/${demo.id}`, localUrl).href;
    });
  return state;
}

async function main() {
  const root = path.resolve(__dirname, '..');
  const scratch = path.join(root, '.tmp');
  await fs.mkdir(scratch, { recursive: true });
  const directory = await fs.mkdtemp(path.join(scratch, 'interactive-qa-'));
  const showcase = process.argv.includes('--showcase');
  const compact = process.argv.includes('--compact');
  const server = showcase ? createShowcaseSite() : createInteractiveSite();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const packaged = process.argv.includes('--packaged');
  if (showcase || compact) {
    const store = new BrowserStore(directory);
    if (showcase) store.state = populateLocalFavorites(createShowcaseState(url), url);
    if (compact)
      store.state.windowBounds = { width: 560, height: 420, maximized: false, sizeKind: 'content' };
    store.save();
  }
  const executable = packaged ? packagedPaths(root).executable : require('electron');
  const env = {
    ...process.env,
    ZACRO_USER_DATA: directory,
    ZACRO_SKIP_ONBOARDING: process.argv.includes('--onboarding') ? '0' : '1',
  };
  delete env.ELECTRON_RUN_AS_NODE;
  console.log(`Opening ${packaged ? 'packaged' : 'development'} Zacro with an isolated test profile.`);
  console.log(`Local test page: ${url}`);
  if (compact) console.log('Compact review: 560×420 content window.');
  if (showcase)
    console.log(
      'Showcase: local Mail, Calendar, Notes and Studio favorites. Visit each once to load its icon; the journal opens first.',
    );
  console.log(
    'Options: --showcase for the demo workspace; --packaged for the built application; --onboarding to show the welcome tour; --compact for a 560×420 content window.',
  );
  console.log(
    `${process.platform === 'darwin' ? 'Quit Zacro with Command-Q' : 'Close the browser'} when finished. No real browser profile is modified.`,
  );
  const args = packaged ? [] : [root];
  if (!showcase) args.push(url);
  const child = spawn(executable, args, { cwd: root, env, windowsHide: false, stdio: 'inherit' });
  let finished = false;
  async function finish(code = 0) {
    if (finished) return;
    finished = true;
    server.closeAllConnections();
    server.close();
    // Only remove the exact temporary fixture profile created above, after
    // resolving and checking it remains inside this repository's scratch area.
    const target = path.resolve(directory);
    if (path.dirname(target) === path.resolve(scratch) && path.basename(target).startsWith('interactive-qa-'))
      await fs
        .rm(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 })
        .catch((error) => {
          console.warn(`Test profile retained at ${target}: ${error.message}`);
        });
    process.exitCode = code;
  }
  child.once('error', (error) => {
    console.error(error.message);
    void finish(1);
  });
  child.once('close', (code) => {
    void finish(code || 0);
  });
  process.once('SIGINT', () => {
    child.kill();
  });
  process.once('SIGTERM', () => {
    child.kill();
  });
}

if (require.main === module)
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

module.exports = { createShowcaseSite, populateLocalFavorites, demoIcon };
