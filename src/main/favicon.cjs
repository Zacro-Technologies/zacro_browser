'use strict';

const { webURL } = require('./security.cjs');

const MAX_BYTES = 128 * 1024;
const MAX_SIDE = 512;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

// Only bounded raster bytes reach the sandboxed shell's image decoder. In
// particular, never parse SVG, run an image decoder in the privileged process,
// write an icon to disk, or give the shell an external image URL.
function pngBytes(bytes) {
  if (bytes.length < 45 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return null;
  let offset = 8;
  let dimensions = null;
  let imageData = false;
  const chunks = [PNG_SIGNATURE];
  while (offset + 12 <= bytes.length) {
    const size = bytes.readUInt32BE(offset);
    if (size > MAX_BYTES || offset + size + 12 > bytes.length) return null;
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (!dimensions && type !== 'IHDR') return null;
    if (type === 'IHDR') {
      if (dimensions || size !== 13) return null;
      const width = bytes.readUInt32BE(offset + 8);
      const height = bytes.readUInt32BE(offset + 12);
      if (!width || !height || width > MAX_SIDE || height > MAX_SIDE) return null;
      dimensions = { width, height };
    }
    if (type === 'acTL') return null; // animated favicons are unnecessary work
    if (type === 'IDAT') imageData = true;
    // Strip compressed metadata and ancillary payloads; keep original chunk
    // CRCs for Chromium to validate when decoding the remaining image.
    if (['IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'].includes(type))
      chunks.push(bytes.subarray(offset, offset + size + 12));
    if (type === 'IEND') {
      if (size !== 0 || !imageData) return null;
      return { bytes: Buffer.concat(chunks), ...dimensions };
    }
    offset += size + 12;
  }
  return null;
}

function normalizeRaster(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > MAX_BYTES) return null;
  const png = pngBytes(bytes);
  if (png) return `data:image/png;base64,${png.bytes.toString('base64')}`;
  if (bytes.length < 22 || bytes.readUInt32LE(0) !== 0x00010000) return null;
  const count = bytes.readUInt16LE(4);
  if (!count || count > 32 || 6 + count * 16 > bytes.length) return null;
  const icons = [];
  for (let index = 0; index < count; index++) {
    const entry = bytes.subarray(6 + index * 16, 22 + index * 16);
    const width = entry[0] || 256;
    const height = entry[1] || 256;
    const size = entry.readUInt32LE(8);
    const offset = entry.readUInt32LE(12);
    if (!size || offset < 6 + count * 16 || offset + size > bytes.length) continue;
    const data = bytes.subarray(offset, offset + size);
    const embedded = pngBytes(data);
    if (embedded) {
      if (embedded.width !== width || embedded.height !== height) continue;
      icons.push({
        score: Math.abs(width - 32),
        value: `data:image/png;base64,${embedded.bytes.toString('base64')}`,
      });
      continue;
    }
    // Restrict legacy ICOs to simple bounded uncompressed RGB/RGBA DIBs.
    if (data.length < 40 || data.readUInt32LE(0) !== 40) continue;
    const bits = data.readUInt16LE(14);
    if (
      data.readInt32LE(4) !== width ||
      data.readInt32LE(8) !== height * 2 ||
      data.readUInt16LE(12) !== 1 ||
      ![24, 32].includes(bits) ||
      data.readUInt32LE(16) !== 0
    )
      continue;
    const pixels = Math.ceil((width * bits) / 32) * 4 * height;
    if (data.length < 40 + pixels) continue;
    const directory = Buffer.alloc(22);
    directory.writeUInt16LE(1, 2);
    directory.writeUInt16LE(1, 4);
    entry.copy(directory, 6);
    directory.writeUInt32LE(22, 18);
    icons.push({
      score: Math.abs(width - 32),
      value: `data:image/x-icon;base64,${Buffer.concat([directory, data]).toString('base64')}`,
    });
  }
  return icons.sort((left, right) => left.score - right.score)[0]?.value || null;
}

class FaviconLoader {
  constructor({ timeoutMs = 4000 } = {}) {
    this.timeoutMs = timeoutMs;
    this.cache = new WeakMap();
    this.active = 0;
  }

  clear(session) {
    this.cache.delete(session);
  }

  async load(session, pageURL, urls = [], { signal } = {}) {
    const page = webURL(pageURL);
    if (!page || signal?.aborted || typeof session?.fetch !== 'function') return null;
    const origin = new URL(page).origin;
    const candidates = [...new Set((Array.isArray(urls) ? urls : []).slice(0, 8))]
      .filter((url) => webURL(url) && new URL(url).origin === origin)
      .slice(0, 2);
    candidates.push(`${origin}/favicon.ico`);
    let cache = this.cache.get(session);
    if (!cache) this.cache.set(session, (cache = new Map()));
    for (const url of [...new Set(candidates)]) {
      if (signal?.aborted || this.cache.get(session) !== cache) return null;
      const cached = cache.get(url);
      if (cached && cached.expires > Date.now()) {
        if (cached.value) return cached.value;
        continue;
      }
      if (this.active >= 4) return null;
      const value = await this.fetch(session, url, signal);
      if (signal?.aborted || this.cache.get(session) !== cache) return null;
      if (cache.size >= 64) cache.delete(cache.keys().next().value);
      cache.set(url, { value, expires: Date.now() + (value ? 15 * 60_000 : 60_000) });
      if (value) return value;
    }
    return null;
  }

  async fetch(session, url, outerSignal) {
    this.active++;
    const controller = new AbortController();
    const cancel = () => controller.abort();
    outerSignal?.addEventListener('abort', cancel, { once: true });
    const timer = setTimeout(cancel, this.timeoutMs);
    timer.unref?.();
    let reader;
    try {
      if (outerSignal?.aborted) return null;
      const response = await session.fetch(url, {
        method: 'GET',
        redirect: 'error',
        signal: controller.signal,
        headers: { Accept: 'image/png,image/x-icon,image/vnd.microsoft.icon' },
      });
      if (
        response.status !== 200 ||
        response.redirected ||
        Number(response.headers.get('content-length')) > MAX_BYTES
      )
        return null;
      const mime = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      if (
        !['image/png', 'image/x-icon', 'image/vnd.microsoft.icon', 'application/octet-stream', ''].includes(
          mime,
        )
      )
        return null;
      reader = response.body?.getReader();
      if (!reader) return null;
      const chunks = [];
      let length = 0;
      while (!controller.signal.aborted) {
        const { value, done } = await reader.read();
        if (done) return normalizeRaster(Buffer.concat(chunks, length));
        length += value.byteLength;
        if (length > MAX_BYTES) return null;
        chunks.push(Buffer.from(value));
      }
    } catch {
      // Favicons are optional; retain a stable monogram on invalid data/offline.
    } finally {
      clearTimeout(timer);
      outerSignal?.removeEventListener('abort', cancel);
      controller.abort();
      await reader?.cancel().catch(() => {});
      this.active--;
    }
    return null;
  }
}

module.exports = { FaviconLoader, normalizeRaster, MAX_BYTES };
