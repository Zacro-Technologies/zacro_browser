'use strict';

// Header-complete, non-runnable fixtures: a 64-bit Mach-O __TEXT segment or a
// PE32+ image with one .text section. No toolchain or native execution required.
function nativeBinary(platform, arch, executable = false) {
  if (platform === 'darwin') {
    const bytes = Buffer.alloc(104);
    bytes.writeUInt32LE(0xfeedfacf, 0);
    bytes.writeUInt32LE(arch === 'arm64' ? 0x0100000c : 0x01000007, 4);
    bytes.writeUInt32LE(arch === 'arm64' ? 0 : 3, 8);
    bytes.writeUInt32LE(executable ? 2 : 6, 12);
    bytes.writeUInt32LE(1, 16);
    bytes.writeUInt32LE(72, 20);
    bytes.writeUInt32LE(0x19, 32); // LC_SEGMENT_64
    bytes.writeUInt32LE(72, 36);
    bytes.write('__TEXT', 40);
    bytes.writeBigUInt64LE(4096n, 64);
    bytes.writeBigUInt64LE(BigInt(bytes.length), 80);
    bytes.writeUInt32LE(5, 88);
    bytes.writeUInt32LE(5, 92);
    return bytes;
  }
  const bytes = Buffer.alloc(1024);
  bytes.write('MZ');
  bytes.writeUInt32LE(128, 0x3c);
  bytes.write('PE\0\0', 128);
  bytes.writeUInt16LE(arch === 'arm64' ? 0xaa64 : 0x8664, 132);
  bytes.writeUInt16LE(1, 134);
  bytes.writeUInt16LE(240, 148);
  bytes.writeUInt16LE(executable ? 0x22 : 0x2022, 150);
  bytes.writeUInt16LE(0x20b, 152); // PE32+ optional header
  bytes.writeUInt32LE(512, 156);
  bytes.writeUInt32LE(0x1000, 168);
  bytes.writeBigUInt64LE(0x140000000n, 176);
  bytes.writeUInt32LE(0x1000, 184);
  bytes.writeUInt32LE(512, 188);
  bytes.writeUInt32LE(0x2000, 208);
  bytes.writeUInt32LE(512, 212);
  bytes.writeUInt16LE(3, 220);
  bytes.writeUInt32LE(16, 260);
  bytes.write('.text', 392);
  bytes.writeUInt32LE(1, 400);
  bytes.writeUInt32LE(0x1000, 404);
  bytes.writeUInt32LE(512, 408);
  bytes.writeUInt32LE(512, 412);
  bytes.writeUInt32LE(0x60000020, 428);
  bytes[512] = 0xc3;
  return bytes;
}

module.exports = { nativeBinary };
