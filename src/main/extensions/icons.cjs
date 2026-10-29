'use strict';
const { deflateSync } = require('node:zlib');

// Encode bounded, unpremultiplied RGBA pixels. PNG avoids native bitmap byte-order
// and alpha conventions, keeping worker/page ImageData identical on every OS.
function chunk(type, bytes) {
  const name = Buffer.from(type),
    content = Buffer.concat([name, bytes]);
  let crc = 0xffffffff;
  for (const byte of content) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  const result = Buffer.alloc(bytes.length + 12);
  result.writeUInt32BE(bytes.length);
  content.copy(result, 4);
  result.writeUInt32BE((crc ^ 0xffffffff) >>> 0, result.length - 4);
  return result;
}
function encode(image, budget) {
  const { width, height, data } = image || {};
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1 ||
    height < 1 ||
    width > 256 ||
    height > 256 ||
    !Array.isArray(data) ||
    data.length !== width * height * 4 ||
    data.length > budget.left ||
    data.some((v) => !Number.isInteger(v) || v < 0 || v > 255)
  )
    throw new Error('Invalid or oversized icon ImageData pixels');
  budget.left -= data.length;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  const pixels = Buffer.from(data),
    rows = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++)
    pixels.copy(rows, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  return (
    'data:image/png;base64,' +
    Buffer.concat([
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      chunk('IHDR', header),
      chunk('IDAT', deflateSync(rows)),
      chunk('IEND', Buffer.alloc(0)),
    ]).toString('base64')
  );
}
function imageDataIcons(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid icon ImageData');
  const budget = { left: 1024 * 1024 };
  if ('width' in value) return encode(value, budget);
  const entries = Object.entries(value);
  if (!entries.length || entries.length > 16 || entries.some(([size]) => !/^[1-9]\d{0,2}$/.test(size)))
    throw new Error('Invalid icon ImageData sizes');
  return Object.fromEntries(entries.map(([size, image]) => [size, encode(image, budget)]));
}
module.exports = { imageDataIcons };
