#!/usr/bin/env node
'use strict';
// Synthetic protocol peer. Never resolves or starts a personal installed host.
const os = require('node:os');
const read = os.endianness() === 'LE' ? 'readUInt32LE' : 'readUInt32BE';
const write = os.endianness() === 'LE' ? 'writeUInt32LE' : 'writeUInt32BE';
let buffer = Buffer.alloc(0);
function frame(value) {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header[write](body.length);
  return Buffer.concat([header, body]);
}
process.stdin.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4 && buffer.length >= 4 + buffer[read](0)) {
    const size = buffer[read](0);
    const value = JSON.parse(buffer.subarray(4, 4 + size));
    buffer = buffer.subarray(4 + size);
    if (value.mode === 'hang') continue;
    if (value.mode === 'exit') process.exit(0);
    if (value.mode === 'stderr') {
      process.stderr.write('SECRET PAYLOAD');
      process.exit(9);
    }
    if (value.mode === 'length') {
      const h = Buffer.alloc(4);
      h[write](0xffffffff);
      process.stdout.write(h);
      continue;
    }
    if (value.mode === 'json' || value.mode === 'utf8') {
      const body = value.mode === 'json' ? Buffer.from('SECRET INVALID JSON') : Buffer.from([0xff]);
      const h = Buffer.alloc(4);
      h[write](body.length);
      process.stdout.write(Buffer.concat([h, body]));
      continue;
    }
    if (value.mode === 'truncated') {
      process.stdout.write(frame({ x: 1 }).subarray(0, 7));
      process.exit(0);
    }
    if (value.mode === 'multiple') {
      process.stdout.write(Buffer.concat([frame(1), frame(2)]));
      continue;
    }
    if (value.mode === 'fragmented') {
      const bytes = frame({ echo: value.text, origin: process.argv[2] });
      process.stdout.write(bytes.subarray(0, 2));
      setTimeout(() => process.stdout.write(bytes.subarray(2, 6)), 5);
      setTimeout(() => process.stdout.write(bytes.subarray(6)), 10);
      continue;
    }
    process.stdout.write(frame(value));
  }
});
